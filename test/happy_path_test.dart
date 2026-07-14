import 'package:flutter_test/flutter_test.dart';
import 'package:elevenlabs_agents/elevenlabs_agents.dart';
import 'helpers/fake_transport.dart';

/// Happy-path tests exercising the real [ConversationClient] against
/// [FakeConversationTransport] / [FakeTokenService] — no LiveKit or HTTP.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  void emitMetadata(
    FakeConversationTransport transport, {
    String conversationId = 'test-conversation-123',
  }) {
    transport.emitData({
      'type': 'conversation_initiation_metadata',
      'conversation_initiation_metadata_event': {
        'conversation_id': conversationId,
        'agent_output_audio_format': 'pcm_16000',
        'user_input_audio_format': 'pcm_16000',
      },
    });
  }

  group('Happy Path - Session Start with AgentId', () {
    test(
      'successfully starts session and transitions through states',
      () async {
        final transport = FakeConversationTransport();
        final statuses = <ConversationStatus>[];
        String? connectedConversationId;

        final client = ConversationClient(
          transport: transport,
          tokenService: FakeTokenService(),
          callbacks: ConversationCallbacks(
            onStatusChange: ({required status}) {
              statuses.add(status);
            },
            onConnect: ({required conversationId}) {
              connectedConversationId = conversationId;
            },
          ),
        );

        // Initial state
        expect(client.status, ConversationStatus.disconnected);
        expect(client.isMuted, true);
        expect(client.conversationId, null);

        // Start session with agentId
        await client.startSession(
          agentId: 'test-agent-123',
          userId: 'user-456',
        );
        emitMetadata(transport);
        await pump();

        // Verify state transitions
        expect(statuses, [
          ConversationStatus.connecting,
          ConversationStatus.connected,
        ]);

        // Verify final state
        expect(client.status, ConversationStatus.connected);
        expect(client.conversationId, isNotNull);
        expect(connectedConversationId, equals(client.conversationId));
        expect(client.isMuted, false);

        await client.endSession();
        client.dispose();
      },
    );

    test('successfully starts session with token', () async {
      final statuses = <ConversationStatus>[];

      final client = ConversationClient(
        transport: FakeConversationTransport(),
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onStatusChange: ({required status}) {
            statuses.add(status);
          },
        ),
      );

      // Start session with token
      await client.startSession(
        conversationToken: 'custom-token-xyz',
        userId: 'user-789',
      );

      // Verify state transitions
      expect(statuses, [
        ConversationStatus.connecting,
        ConversationStatus.connected,
      ]);

      expect(client.status, ConversationStatus.connected);

      await client.endSession();
      client.dispose();
    });

    test('starts session with full configuration', () async {
      final transport = FakeConversationTransport();
      final events = <String>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onStatusChange: ({required status}) {
            events.add('status:${status.name}');
          },
          onConnect: ({required conversationId}) {
            events.add('connected:$conversationId');
          },
        ),
      );

      final overrides = ConversationOverrides(
        agent: AgentOverrides(
          firstMessage: 'Hello! How can I help you?',
          prompt: 'You are a helpful assistant',
          temperature: 0.7,
        ),
        tts: TtsOverrides(voiceId: 'voice-123', stability: 0.5),
      );

      await client.startSession(
        agentId: 'test-agent',
        userId: 'user-123',
        overrides: overrides,
        dynamicVariables: {'user_name': 'Alice', 'tier': 'premium'},
      );
      emitMetadata(transport);
      await pump();

      expect(events, contains('status:connecting'));
      expect(events, contains('status:connected'));
      expect(events, contains('connected:test-conversation-123'));
      expect(client.status, ConversationStatus.connected);

      final sentOverrides = transport.sentMessages.first;
      expect(sentOverrides['type'], 'conversation_initiation_client_data');
      expect(sentOverrides['user_id'], 'user-123');
      expect(
        sentOverrides['dynamic_variables'],
        {'user_name': 'Alice', 'tier': 'premium'},
      );

      await client.endSession();
      client.dispose();
    });
  });

  group('Happy Path - Messaging During Session', () {
    test('sends and receives messages while connected', () async {
      final transport = FakeConversationTransport();
      final messages = <String>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onMessage: ({required message, required source}) {
            messages.add('${source.name}:$message');
          },
        ),
      );

      await client.startSession(agentId: 'test-agent');

      // Send user message
      client.sendUserMessage('Hello, agent!');
      await pump();

      expect(
        transport.sentMessages,
        contains(equals({'type': 'user_message', 'text': 'Hello, agent!'})),
      );

      // Simulate agent response
      transport.emitData({
        'type': 'agent_response',
        'agent_response_event': {
          'agent_response': 'Hi! How can I help?',
          'event_id': 1,
        },
      });
      await pump();
      expect(messages, contains('ai:Hi! How can I help?'));

      await client.endSession();
      client.dispose();
    });

    test('sends contextual updates', () async {
      final transport = FakeConversationTransport();

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(conversationToken: 'test-token');

      client.sendContextualUpdate('User viewing product page');
      await pump();

      expect(
        transport.sentMessages,
        contains(equals({
          'type': 'contextual_update',
          'text': 'User viewing product page',
        })),
      );

      await client.endSession();
      client.dispose();
    });

    test('sends user activity signals', () async {
      final transport = FakeConversationTransport();

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(conversationToken: 'test-token');

      client.sendUserActivity();
      await pump();

      expect(
        transport.sentMessages,
        contains(equals({'type': 'user_activity'})),
      );

      await client.endSession();
      client.dispose();
    });

    test('sends feedback when available', () async {
      final transport = FakeConversationTransport();

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(conversationToken: 'test-token');

      // Feedback becomes available after an agent response with an event id
      transport.emitData({
        'type': 'agent_response',
        'agent_response_event': {'agent_response': 'Hi', 'event_id': 5},
      });
      await pump();
      expect(client.canSendFeedback, true);

      // Send positive feedback
      client.sendFeedback(isPositive: true);
      await pump();

      expect(
        transport.sentMessages,
        contains(equals({'type': 'feedback', 'score': 'like', 'event_id': 5})),
      );

      await client.endSession();
      client.dispose();
    });
  });

  group('Happy Path - Mode Changes', () {
    test('detects when agent starts and stops speaking', () async {
      final transport = FakeConversationTransport();
      final modes = <ConversationMode>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onModeChange: ({required mode}) {
            modes.add(mode);
          },
        ),
      );

      await client.startSession(agentId: 'test-agent');

      // Initially listening
      expect(client.isSpeaking, false);

      // Agent starts speaking
      transport.emitSpeaking(true);
      await pump();

      expect(modes, contains(ConversationMode.speaking));
      expect(client.isSpeaking, true);

      // Agent stops speaking
      transport.emitSpeaking(false);
      await pump();

      expect(modes, contains(ConversationMode.listening));
      expect(client.isSpeaking, false);

      await client.endSession();
      client.dispose();
    });
  });

  group('Happy Path - Audio Controls', () {
    test('mutes and unmutes microphone during session', () async {
      final client = ConversationClient(
        transport: FakeConversationTransport(),
        tokenService: FakeTokenService(),
      );

      await client.startSession(agentId: 'test-agent');

      expect(client.isMuted, false); // Unmuted when connected

      // Mute
      await client.setMicMuted(true);
      expect(client.isMuted, true);

      // Unmute
      await client.setMicMuted(false);
      expect(client.isMuted, false);

      // Toggle
      await client.toggleMute();
      expect(client.isMuted, true);

      await client.toggleMute();
      expect(client.isMuted, false);

      await client.endSession();
      client.dispose();
    });
  });

  group('Happy Path - Session Lifecycle', () {
    test('completes full lifecycle: start, interact, end', () async {
      final transport = FakeConversationTransport();
      final events = <String>[];
      final messages = <String>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onStatusChange: ({required status}) {
            events.add('status:${status.name}');
          },
          onConnect: ({required conversationId}) {
            events.add('connect:$conversationId');
          },
          onDisconnect: (details) {
            events.add('disconnect:${details.reason}');
          },
          onMessage: ({required message, required source}) {
            messages.add('${source.name}:$message');
          },
          onModeChange: ({required mode}) {
            events.add('mode:${mode.name}');
          },
        ),
      );

      // Start
      await client.startSession(agentId: 'test-agent', userId: 'user-123');
      emitMetadata(transport);
      await pump();

      expect(events, contains('status:connecting'));
      expect(events, contains('status:connected'));
      expect(events, contains('connect:test-conversation-123'));

      // Interact
      client.sendUserMessage('Hello');
      await pump();
      expect(
        transport.sentMessages,
        contains(equals({'type': 'user_message', 'text': 'Hello'})),
      );

      transport.emitSpeaking(true);
      await pump();
      expect(events, contains('mode:speaking'));

      transport.emitData({
        'type': 'agent_response',
        'agent_response_event': {
          'agent_response': 'Hi there!',
          'event_id': 1,
        },
      });
      await pump();
      expect(messages, contains('ai:Hi there!'));

      transport.emitSpeaking(false);
      await pump();
      expect(events, contains('mode:listening'));

      // End
      await client.endSession();
      expect(events, contains('status:disconnecting'));
      expect(events, contains('status:disconnected'));
      expect(events, contains('disconnect:user'));
      expect(client.status, ConversationStatus.disconnected);
      expect(client.conversationId, null);

      client.dispose();
    });

    test('handles multiple sessions sequentially', () async {
      final statuses = <ConversationStatus>[];

      final client = ConversationClient(
        transport: FakeConversationTransport(),
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onStatusChange: ({required status}) {
            statuses.add(status);
          },
        ),
      );

      // First session
      await client.startSession(agentId: 'agent-1');
      expect(client.status, ConversationStatus.connected);

      await client.endSession();
      expect(client.status, ConversationStatus.disconnected);

      // Second session
      await client.startSession(agentId: 'agent-2');
      expect(client.status, ConversationStatus.connected);

      await client.endSession();
      expect(client.status, ConversationStatus.disconnected);

      // Verify state transitions for both sessions
      expect(statuses, [
        ConversationStatus.connecting,
        ConversationStatus.connected,
        ConversationStatus.disconnecting,
        ConversationStatus.disconnected,
        ConversationStatus.connecting,
        ConversationStatus.connected,
        ConversationStatus.disconnecting,
        ConversationStatus.disconnected,
      ]);

      client.dispose();
    });
  });

  group('Happy Path - Listener Notifications', () {
    test('notifies listeners on state changes', () async {
      final transport = FakeConversationTransport();
      int notifyCount = 0;

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      void listener() {
        notifyCount++;
      }

      client.addListener(listener);

      // Start session triggers notifications
      final initialCount = notifyCount;
      await client.startSession(agentId: 'test-agent');
      expect(notifyCount, greaterThan(initialCount));

      // Mute triggers notification
      final beforeMute = notifyCount;
      await client.setMicMuted(true);
      expect(notifyCount, greaterThan(beforeMute));

      // Speaking state change triggers notification
      final beforeSpeaking = notifyCount;
      transport.emitSpeaking(true);
      await pump();
      expect(notifyCount, greaterThan(beforeSpeaking));

      client.removeListener(listener);
      await client.endSession();
      client.dispose();
    });
  });
}
