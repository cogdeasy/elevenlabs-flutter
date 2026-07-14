import 'package:flutter_test/flutter_test.dart';
import 'package:elevenlabs_agents/elevenlabs_agents.dart';

import 'helpers/fake_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Session modes - voice (default)', () {
    test('enables microphone and sends no text_only override', () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(agentId: 'agent-1');

      expect(client.sessionMode, ConversationSessionMode.voice);
      expect(transport.connectCalls.single.enableMicrophone, true);
      expect(client.isMuted, false);

      final overrides = transport.sentMessages.single;
      expect(overrides['type'], 'conversation_initiation_client_data');
      expect(
        overrides['conversation_config_override'],
        isNot(contains('conversation')),
      );

      await client.endSession();
      client.dispose();
    });
  });

  group('Session modes - textOnly', () {
    test('does not enable microphone and sends text_only override', () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(
        agentId: 'agent-1',
        sessionMode: ConversationSessionMode.textOnly,
      );

      expect(client.sessionMode, ConversationSessionMode.textOnly);
      expect(transport.connectCalls.single.enableMicrophone, false);
      expect(client.isMuted, true);

      final overrides = transport.sentMessages.single;
      expect(overrides['type'], 'conversation_initiation_client_data');
      final configOverride =
          overrides['conversation_config_override'] as Map<String, dynamic>;
      final conversation =
          configOverride['conversation'] as Map<String, dynamic>;
      expect(conversation['text_only'], true);

      await client.endSession();
      client.dispose();
    });

    test('preserves caller-provided overrides when injecting text_only',
        () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(
        agentId: 'agent-1',
        sessionMode: ConversationSessionMode.textOnly,
        overrides: ConversationOverrides(
          agent: AgentOverrides(prompt: 'You are terse'),
          conversation: ConversationSettingsOverrides(
            maxDurationSeconds: 120,
            turnTimeoutSeconds: 10,
          ),
        ),
      );

      final overrides = transport.sentMessages.single;
      final configOverride =
          overrides['conversation_config_override'] as Map<String, dynamic>;
      final agent = configOverride['agent'] as Map<String, dynamic>;
      expect(agent['prompt'], 'You are terse');
      final conversation =
          configOverride['conversation'] as Map<String, dynamic>;
      expect(conversation['max_duration_seconds'], 120);
      expect(conversation['turn_timeout_seconds'], 10);
      expect(conversation['text_only'], true);

      await client.endSession();
      client.dispose();
    });

    test('caller-provided textOnly: false is overridden to true', () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(
        agentId: 'agent-1',
        sessionMode: ConversationSessionMode.textOnly,
        overrides: ConversationOverrides(
          conversation: ConversationSettingsOverrides(textOnly: false),
        ),
      );

      final overrides = transport.sentMessages.single;
      final configOverride =
          overrides['conversation_config_override'] as Map<String, dynamic>;
      final conversation =
          configOverride['conversation'] as Map<String, dynamic>;
      expect(conversation['text_only'], true);

      await client.endSession();
      client.dispose();
    });

    test('mic controls report an error instead of publishing audio', () async {
      final errors = <String>[];
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onError: (message, [context]) => errors.add(message),
        ),
      );

      await client.startSession(
        agentId: 'agent-1',
        sessionMode: ConversationSessionMode.textOnly,
      );

      await client.setMicMuted(false);
      expect(client.isMuted, true);
      expect(errors, hasLength(1));
      expect(errors.single, contains('textOnly'));

      await client.toggleMute();
      expect(client.isMuted, true);
      expect(errors, hasLength(2));

      await client.endSession();
      client.dispose();
    });

    test('can still send and receive text messages', () async {
      final received = <String>[];
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onMessage: ({required message, required source}) {
            received.add('${source.name}:$message');
          },
        ),
      );

      await client.startSession(
        agentId: 'agent-1',
        sessionMode: ConversationSessionMode.textOnly,
      );

      client.sendUserMessage('Hello in text');
      await Future<void>.delayed(Duration.zero);
      expect(transport.sentMessages.last['type'], 'user_message');
      expect(transport.sentMessages.last['text'], 'Hello in text');

      transport.emitData({
        'type': 'agent_response',
        'agent_response_event': {
          'agent_response': 'Hi from the agent',
          'event_id': 1,
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(received, contains('ai:Hi from the agent'));

      await client.endSession();
      client.dispose();
    });
  });

  group('Session modes - listenOnly', () {
    test('does not enable microphone and sends no text_only override',
        () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(
        agentId: 'agent-1',
        sessionMode: ConversationSessionMode.listenOnly,
      );

      expect(client.sessionMode, ConversationSessionMode.listenOnly);
      expect(transport.connectCalls.single.enableMicrophone, false);
      expect(client.isMuted, true);

      final overrides = transport.sentMessages.single;
      final configOverride =
          overrides['conversation_config_override'] as Map<String, dynamic>;
      expect(configOverride.containsKey('conversation'), false);

      await client.endSession();
      client.dispose();
    });

    test('mic controls report an error', () async {
      final errors = <String>[];
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onError: (message, [context]) => errors.add(message),
        ),
      );

      await client.startSession(
        agentId: 'agent-1',
        sessionMode: ConversationSessionMode.listenOnly,
      );

      await client.setMicMuted(false);
      expect(errors.single, contains('listenOnly'));
      expect(client.isMuted, true);

      await client.endSession();
      client.dispose();
    });
  });

  group('Session modes - sequential sessions', () {
    test('mode resets between sessions', () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(
        agentId: 'agent-1',
        sessionMode: ConversationSessionMode.textOnly,
      );
      expect(client.sessionMode, ConversationSessionMode.textOnly);
      await client.endSession();

      await client.startSession(agentId: 'agent-1');
      expect(client.sessionMode, ConversationSessionMode.voice);
      expect(transport.connectCalls.last.enableMicrophone, true);

      await client.endSession();
      client.dispose();
    });
  });
}
