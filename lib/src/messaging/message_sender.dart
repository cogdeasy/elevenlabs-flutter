import '../connection/conversation_transport.dart';

/// Handles sending messages to the agent via the transport data channel
class MessageSender {
  final ConversationTransport transport;

  MessageSender(this.transport);

  /// Sends a user text message to the agent
  Future<void> sendUserMessage(String text) async {
    await transport.sendMessage({'type': 'user_message', 'text': text});
  }

  /// Sends a contextual update to the agent
  Future<void> sendContextualUpdate(String text) async {
    await transport.sendMessage({'type': 'contextual_update', 'text': text});
  }

  /// Sends a user activity signal
  Future<void> sendUserActivity() async {
    await transport.sendMessage({'type': 'user_activity'});
  }

  /// Sends feedback for the last agent response
  Future<void> sendFeedback({
    required bool isPositive,
    required int eventId,
  }) async {
    await transport.sendMessage({
      'type': 'feedback',
      'score': isPositive ? 'like' : 'dislike',
      'event_id': eventId,
    });
  }

  /// Sends a client tool result
  Future<void> sendClientToolResult({
    required String toolCallId,
    required Map<String, dynamic> result,
  }) async {
    await transport.sendMessage({
      'type': 'client_tool_result',
      'tool_call_id': toolCallId,
      'result': result,
    });
  }
}
