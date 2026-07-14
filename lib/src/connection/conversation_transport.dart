/// Connection state of a [ConversationTransport].
enum TransportConnectionState {
  /// Not connected to the server
  disconnected,

  /// Attempting to connect
  connecting,

  /// Connected and ready
  connected,

  /// Attempting to re-establish a dropped connection
  reconnecting,
}

/// Abstraction over the realtime transport used to talk to an agent.
///
/// The default implementation is `LiveKitManager` (WebRTC via LiveKit), but
/// any implementation can be injected into `ConversationClient` — e.g. a fake
/// transport in tests — so conversation logic can be exercised without a real
/// network connection.
abstract class ConversationTransport {
  /// Stream of incoming data messages (decoded protocol events)
  Stream<Map<String, dynamic>> get dataStream;

  /// Stream of connection state changes
  Stream<TransportConnectionState> get stateStream;

  /// Stream of disconnect events with reasons ('agent', 'user', or 'error')
  Stream<String> get disconnectStream;

  /// Stream that emits when the transport is fully ready to send messages
  Stream<void> get roomReadyStream;

  /// Stream that emits when the agent starts/stops speaking
  Stream<bool> get speakingStateStream;

  /// Stream of the agent's real-time audio level (0-1)
  Stream<double> get agentAudioLevelStream;

  /// Stream of the local user's audio level (0-1)
  Stream<double> get userAudioLevelStream;

  /// Whether the microphone is muted
  bool get isMuted;

  /// Connects to the server.
  ///
  /// When [enableMicrophone] is false, no local audio publisher is created —
  /// used for text-only and listen-only sessions.
  Future<void> connect(
    String serverUrl,
    String token, {
    bool enableMicrophone = true,
  });

  /// Sends a data message to the agent
  Future<void> sendMessage(Map<String, dynamic> message);

  /// Sets the microphone mute state
  Future<void> setMicMuted(bool muted);

  /// Toggles the microphone mute state
  Future<void> toggleMute();

  /// Disconnects from the server and cleans up connection resources
  Future<void> disconnect();

  /// Disposes of all resources
  Future<void> dispose();
}
