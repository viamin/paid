# frozen_string_literal: true

module Tools
  # Read-only, on-demand evidence retrieval for an item-scoped Inbox chat.
  # @spec QUESTION-EXPLORATION-017 @spec OPERATOR-INBOX-002I
  class GetInboxChatContext < BaseTool
    authorize :manage_issues?, ->(_args) { project_for_session! }, policy_class: ProjectPolicy

    def self.tool_name = "get_inbox_chat_context"

    def self.description
      "Retrieve current, authorized evidence for this Inbox item without changing its state."
    end

    def self.available_for_chat?(user:, session:)
      session&.interactive_inbox_chat? &&
        Inbox::InteractiveChatAccess.allowed?(user:, project: session.project)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          sections: {
            type: "array",
            items: { type: "string", enum: Inbox::ChatContext::SECTIONS },
            description: "Evidence sections to retrieve on demand"
          }
        },
        required: [ "sections" ]
      }
    end

    def perform(sections:)
      Inbox::ChatContext.call(chat_session: session, user:, sections:)
    end

    private

    def project_for_session!
      session.project || raise(ArgumentError, "get_inbox_chat_context requires an Inbox chat with a project")
    end
  end
end
