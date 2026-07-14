import 'package:flutter_test/flutter_test.dart';
import 'package:elevenlabs_agents/elevenlabs_agents.dart';

import '../helpers/fake_transport.dart';

/// Integration tests exercising the real ConversationClient, MessageHandler
/// and MessageSender against a fake transport, verifying protocol/event
/// handling end to end without a LiveKit connection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  group('Session lifecycle', () {
    test('startSession fetches token, connects, and sends overrides', () async {
      final transport = FakeConversationTransport();
      final tokenService = FakeTokenService(token: 'token-abc');
      final statuses = <ConversationStatus>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: tokenService,
        callbacks: ConversationCallbacks(
          onStatusChange: ({required status}) => statuses.add(status),
        ),
      );

      await client.startSession(agentId: 'agent-42', userId: 'user-7');

      expect(tokenService.fetchedAgentIds, ['agent-42']);
      expect(transport.connectCalls.single.token, 'token-abc');
      expect(
        transport.connectCalls.single.serverUrl,
        'wss://livekit.rtc.elevenlabs.io',
      );
      expect(statuses, [
        ConversationStatus.connecting,
        ConversationStatus.connected,
      ]);

      final overrides = transport.sentMessages.single;
      expect(overrides['type'], 'conversation_initiation_client_data');
      expect(overrides['user_id'], 'user-7');
      expect(overrides['source_info'], containsPair('source', 'flutter_sdk'));

      await client.endSession();
      client.dispose();
    });

    test('conversation metadata sets conversationId and fires onConnect',
        () async {
      final transport = FakeConversationTransport();
      String? connectedId;

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onConnect: ({required conversationId}) {
            connectedId = conversationId;
          },
        ),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitData({
        'type': 'conversation_initiation_metadata',
        'conversation_initiation_metadata_event': {
          'conversation_id': 'conv-123',
          'agent_output_audio_format': 'pcm_16000',
          'user_input_audio_format': 'pcm_16000',
        },
      });
      await pump();

      expect(client.conversationId, 'conv-123');
      expect(connectedId, 'conv-123');

      await client.endSession();
      client.dispose();
    });

    test('failed connect surfaces error and resets status', () async {
      final transport = FakeConversationTransport()
        ..connectError = Exception('boom');
      final errors = <String>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onError: (message, [context]) => errors.add(message),
        ),
      );

      await expectLater(
        client.startSession(agentId: 'agent-1'),
        throwsA(isA<Exception>()),
      );
      expect(client.status, ConversationStatus.disconnected);
      expect(errors, contains('Failed to start session'));

      client.dispose();
    });

    test('agent disconnect ends the session with reason', () async {
      final transport = FakeConversationTransport();
      final disconnects = <String>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onDisconnect: (details) => disconnects.add(details.reason),
        ),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitDisconnect('agent');
      await pump();

      expect(disconnects, ['agent']);
      expect(client.status, ConversationStatus.disconnected);

      client.dispose();
    });
  });

  group('Transport connection state', () {
    test('reconnecting transport state is reported via status', () async {
      final transport = FakeConversationTransport();
      final statuses = <ConversationStatus>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onStatusChange: ({required status}) => statuses.add(status),
        ),
      );

      await client.startSession(agentId: 'agent-1');
      expect(client.status, ConversationStatus.connected);

      // Connection drops and the transport starts reconnecting
      transport.emitState(TransportConnectionState.reconnecting);
      await pump();
      expect(client.status, ConversationStatus.reconnecting);

      // Transport recovers
      transport.emitState(TransportConnectionState.connected);
      await pump();
      expect(client.status, ConversationStatus.connected);

      expect(statuses, [
        ConversationStatus.connecting,
        ConversationStatus.connected,
        ConversationStatus.reconnecting,
        ConversationStatus.connected,
      ]);

      await client.endSession();
      client.dispose();
    });

    test('state events during initial connect do not disturb status', () async {
      final transport = FakeConversationTransport();
      final statuses = <ConversationStatus>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onStatusChange: ({required status}) => statuses.add(status),
        ),
      );

      // connect() emits connecting/connected on the state stream; the
      // client's own status flow must remain connecting -> connected
      await client.startSession(agentId: 'agent-1');
      await pump();

      expect(statuses, [
        ConversationStatus.connecting,
        ConversationStatus.connected,
      ]);

      await client.endSession();
      client.dispose();
    });

    test('sends are still attempted while reconnecting', () async {
      final transport = FakeConversationTransport();

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitState(TransportConnectionState.reconnecting);
      await pump();
      expect(client.status, ConversationStatus.reconnecting);

      client.sendUserMessage('still there?');
      await pump();
      expect(
        transport.sentMessages.last,
        containsPair('type', 'user_message'),
      );

      await client.endSession();
      client.dispose();
    });

    test('reconnecting state after disconnect is ignored', () async {
      final transport = FakeConversationTransport();

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(agentId: 'agent-1');
      await client.endSession();
      expect(client.status, ConversationStatus.disconnected);

      transport.emitState(TransportConnectionState.reconnecting);
      await pump();
      expect(client.status, ConversationStatus.disconnected);

      client.dispose();
    });
  });

  group('Protocol events', () {
    test('ping is answered with pong carrying the event id', () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitData({
        'type': 'ping',
        'ping_event': {'event_id': 99},
      });
      await pump();

      expect(
        transport.sentMessages,
        contains(equals({'type': 'pong', 'event_id': 99})),
      );

      await client.endSession();
      client.dispose();
    });

    test('user and agent transcripts reach callbacks', () async {
      final transport = FakeConversationTransport();
      final transcripts = <String>[];
      final messages = <String>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onUserTranscript: ({required transcript, required eventId}) {
            transcripts.add('$eventId:$transcript');
          },
          onMessage: ({required message, required source}) {
            messages.add('${source.name}:$message');
          },
        ),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitData({
        'type': 'user_transcript',
        'user_transcription_event': {
          'user_transcript': 'Hello there',
          'event_id': 3,
        },
      });
      transport.emitData({
        'type': 'agent_response',
        'agent_response_event': {
          'agent_response': 'General Kenobi',
          'event_id': 4,
        },
      });
      await pump();

      expect(transcripts, ['3:Hello there']);
      expect(messages, ['ai:General Kenobi']);

      await client.endSession();
      client.dispose();
    });

    test('agent_response event id enables feedback and feedback is sent',
        () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(agentId: 'agent-1');
      expect(client.canSendFeedback, false);

      transport.emitData({
        'type': 'agent_response',
        'agent_response_event': {'agent_response': 'Hi', 'event_id': 7},
      });
      await pump();
      expect(client.canSendFeedback, true);

      client.sendFeedback(isPositive: true);
      await pump();

      expect(client.canSendFeedback, false);
      expect(
        transport.sentMessages,
        contains(
          equals({'type': 'feedback', 'score': 'like', 'event_id': 7}),
        ),
      );

      await client.endSession();
      client.dispose();
    });

    test('client tool call executes registered tool and sends result',
        () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        clientTools: {
          'get_battery': _StubTool(
            (params) async => ClientToolResult.success('87%'),
          ),
        },
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitData({
        'type': 'client_tool_call',
        'client_tool_call': {
          'tool_call_id': 'call-1',
          'tool_name': 'get_battery',
          'parameters': <String, dynamic>{},
          'event_id': 1,
        },
      });
      await pump();
      await pump();

      expect(
        transport.sentMessages,
        contains(equals({
          'type': 'client_tool_result',
          'tool_call_id': 'call-1',
          'result': '87%',
          'is_error': false,
        })),
      );

      await client.endSession();
      client.dispose();
    });

    test('unregistered client tool call fires onUnhandledClientToolCall',
        () async {
      final transport = FakeConversationTransport();
      final unhandled = <String>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onUnhandledClientToolCall: (toolCall) {
            unhandled.add(toolCall.toolName);
          },
        ),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitData({
        'type': 'client_tool_call',
        'client_tool_call': {
          'tool_call_id': 'call-2',
          'tool_name': 'unknown_tool',
          'parameters': <String, dynamic>{},
          'event_id': 1,
        },
      });
      await pump();

      expect(unhandled, ['unknown_tool']);

      await client.endSession();
      client.dispose();
    });

    test('agent_tool_request fires user-provided onAgentToolRequest', () async {
      final transport = FakeConversationTransport();
      final requests = <String>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onAgentToolRequest: ({required toolName, required toolCallId}) {
            requests.add('$toolName:$toolCallId');
          },
        ),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitData({
        'type': 'agent_tool_request',
        'agent_tool_request': {
          'tool_name': 'lookup_weather',
          'tool_call_id': 'call-9',
          'tool_type': 'webhook',
          'parameters': <String, dynamic>{},
        },
      });
      await pump();

      expect(requests, ['lookup_weather:call-9']);

      await client.endSession();
      client.dispose();
    });

    test('vad_score event reaches callback', () async {
      final transport = FakeConversationTransport();
      final scores = <double>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onVadScore: ({required vadScore}) => scores.add(vadScore),
        ),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitData({
        'type': 'vad_score',
        'vad_score_event': {'vad_score': 0.85},
      });
      await pump();

      expect(scores, [0.85]);

      await client.endSession();
      client.dispose();
    });
  });

  group('Speaking state and audio levels', () {
    test('speaking state drives mode changes', () async {
      final transport = FakeConversationTransport();
      final modes = <ConversationMode>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onModeChange: ({required mode}) => modes.add(mode),
        ),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitSpeaking(true);
      await pump();
      expect(client.isSpeaking, true);
      expect(modes, contains(ConversationMode.speaking));

      transport.emitSpeaking(false);
      await pump();
      expect(client.isSpeaking, false);
      expect(modes, contains(ConversationMode.listening));

      await client.endSession();
      client.dispose();
    });

    test('agent and user audio levels reach callbacks', () async {
      final transport = FakeConversationTransport();
      final agentLevels = <double>[];
      final userLevels = <double>[];

      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
        callbacks: ConversationCallbacks(
          onAgentAudioLevel: ({required audioLevel}) {
            agentLevels.add(audioLevel);
          },
          onUserAudioLevel: ({required audioLevel}) {
            userLevels.add(audioLevel);
          },
        ),
      );

      await client.startSession(agentId: 'agent-1');
      transport.emitAgentAudioLevel(0.4);
      transport.emitAgentAudioLevel(0.0);
      transport.emitUserAudioLevel(0.9);
      await pump();

      expect(agentLevels, [0.4, 0.0]);
      expect(userLevels, [0.9]);

      await client.endSession();
      client.dispose();
    });
  });

  group('Outbound messages', () {
    test('sendUserMessage, sendContextualUpdate, sendUserActivity', () async {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      await client.startSession(agentId: 'agent-1');
      client.sendUserMessage('hi');
      client.sendContextualUpdate('on checkout page');
      client.sendUserActivity();
      await pump();

      expect(
        transport.sentMessages,
        containsAll([
          equals({'type': 'user_message', 'text': 'hi'}),
          equals({'type': 'contextual_update', 'text': 'on checkout page'}),
          equals({'type': 'user_activity'}),
        ]),
      );

      await client.endSession();
      client.dispose();
    });

    test('sending while disconnected throws StateError', () {
      final transport = FakeConversationTransport();
      final client = ConversationClient(
        transport: transport,
        tokenService: FakeTokenService(),
      );

      expect(() => client.sendUserMessage('hi'), throwsStateError);
      expect(() => client.sendUserActivity(), throwsStateError);

      client.dispose();
    });
  });
}

class _StubTool implements ClientTool {
  _StubTool(this._execute);

  final Future<ClientToolResult?> Function(Map<String, dynamic>) _execute;

  @override
  Future<ClientToolResult?> execute(Map<String, dynamic> parameters) =>
      _execute(parameters);
}
