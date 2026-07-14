import 'dart:async';
import 'package:elevenlabs_agents/elevenlabs_agents.dart';

/// Fake [ConversationTransport] for exercising real conversation logic
/// (ConversationClient, MessageHandler, MessageSender) without LiveKit.
class FakeConversationTransport implements ConversationTransport {
  final _dataController = StreamController<Map<String, dynamic>>.broadcast();
  final _stateController =
      StreamController<TransportConnectionState>.broadcast();
  final _disconnectController = StreamController<String>.broadcast();
  final _roomReadyController = StreamController<void>.broadcast();
  final _speakingController = StreamController<bool>.broadcast();
  final _agentAudioLevelController = StreamController<double>.broadcast();
  final _userAudioLevelController = StreamController<double>.broadcast();

  /// Messages sent through [sendMessage], in order
  final List<Map<String, dynamic>> sentMessages = [];

  /// Recorded connect() invocations as (serverUrl, token, enableMicrophone)
  final List<({String serverUrl, String token, bool enableMicrophone})>
      connectCalls = [];

  bool connected = false;
  bool micEnabled = false;
  bool disposed = false;

  /// When set, connect() throws this error
  Object? connectError;

  /// When set, sendMessage() throws this error
  Object? sendError;

  @override
  Stream<Map<String, dynamic>> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionState> get stateStream => _stateController.stream;

  @override
  Stream<String> get disconnectStream => _disconnectController.stream;

  @override
  Stream<void> get roomReadyStream => _roomReadyController.stream;

  @override
  Stream<bool> get speakingStateStream => _speakingController.stream;

  @override
  Stream<double> get agentAudioLevelStream => _agentAudioLevelController.stream;

  @override
  Stream<double> get userAudioLevelStream => _userAudioLevelController.stream;

  @override
  bool get isMuted => !micEnabled;

  @override
  Future<void> connect(
    String serverUrl,
    String token, {
    bool enableMicrophone = true,
  }) async {
    connectCalls.add((
      serverUrl: serverUrl,
      token: token,
      enableMicrophone: enableMicrophone,
    ));

    final error = connectError;
    if (error != null) {
      throw error;
    }

    _stateController.add(TransportConnectionState.connecting);
    await Future<void>.delayed(Duration.zero);
    connected = true;
    micEnabled = enableMicrophone;
    _stateController.add(TransportConnectionState.connected);
    _roomReadyController.add(null);
  }

  @override
  Future<void> sendMessage(Map<String, dynamic> message) async {
    if (!connected) {
      throw StateError('Not connected to room');
    }
    final error = sendError;
    if (error != null) {
      throw error;
    }
    sentMessages.add(message);
  }

  @override
  Future<void> setMicMuted(bool muted) async {
    micEnabled = !muted;
  }

  @override
  Future<void> toggleMute() async {
    micEnabled = !micEnabled;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    micEnabled = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await disconnect();
    await _dataController.close();
    await _stateController.close();
    await _disconnectController.close();
    await _roomReadyController.close();
    await _speakingController.close();
    await _agentAudioLevelController.close();
    await _userAudioLevelController.close();
  }

  // ----- Test drivers -----

  /// Injects an incoming protocol event, as if received from the agent
  void emitData(Map<String, dynamic> message) => _dataController.add(message);

  /// Emits a transport connection state change
  void emitState(TransportConnectionState state) => _stateController.add(state);

  /// Emits an agent disconnect event with [reason]
  void emitDisconnect(String reason) => _disconnectController.add(reason);

  /// Emits an agent speaking state change
  void emitSpeaking(bool speaking) => _speakingController.add(speaking);

  /// Emits an agent audio level sample
  void emitAgentAudioLevel(double level) =>
      _agentAudioLevelController.add(level);

  /// Emits a local user audio level sample
  void emitUserAudioLevel(double level) => _userAudioLevelController.add(level);
}

/// Fake [TokenService] that returns a canned token without HTTP
class FakeTokenService extends TokenService {
  FakeTokenService({this.token = 'fake-token', this.shouldFail = false});

  final String token;
  final bool shouldFail;

  /// Recorded fetchToken agentIds
  final List<String> fetchedAgentIds = [];

  @override
  Future<({String token})> fetchToken({
    required String agentId,
    String? environment,
  }) async {
    fetchedAgentIds.add(agentId);
    if (shouldFail) {
      throw Exception('Failed to fetch token');
    }
    return (token: token);
  }
}
