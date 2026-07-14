/// Connection status of the conversation
enum ConversationStatus {
  /// Not connected to the agent
  disconnected,

  /// Attempting to connect
  connecting,

  /// Connected and ready for conversation
  connected,

  /// In the process of disconnecting
  disconnecting,
}

/// Mode of the conversation
enum ConversationMode {
  /// Agent is listening to the user
  listening,

  /// Agent is speaking
  speaking,
}

/// How the local user participates in a conversation session
enum ConversationSessionMode {
  /// Full voice conversation: microphone is published and agent audio plays
  voice,

  /// Agent audio plays but the microphone is never published.
  /// Interaction happens via `sendUserMessage`. No microphone permission
  /// is requested.
  listenOnly,

  /// Pure text chat: the microphone is never published and the
  /// `text_only` conversation override is sent so the agent responds with
  /// text instead of audio. No microphone permission is requested.
  textOnly,
}

/// Role in the conversation
enum Role {
  /// User/customer role
  user,

  /// AI agent role
  ai,
}
