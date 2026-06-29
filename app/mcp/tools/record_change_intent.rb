# frozen_string_literal: true

module Tools
  class RecordChangeIntent < BaseTool
    authorize :update?, ->(_args) { project_for_session! }, policy_class: ProjectPolicy

    def self.tool_name = "record_change_intent"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch

    def self.description
      "Create a draft Change Intent Record for the current project, then wait for human approval to activate it."
    end

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? do |project|
        policy_allows?(user:, record: project, query: :update?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          title: { type: "string", description: "Short title for the Change Intent Record" },
          intent: { type: "string", description: "What the user is trying to accomplish" },
          behavior: { type: "string", description: "Expected behavior, examples, or scenarios" },
          constraints: { type: "string", description: "Non-obvious constraints or requirements" },
          decisions_made: { type: "string", description: "Rejected alternatives or decisions already made" }
        },
        required: %w[title intent]
      }
    end

    def perform(title:, intent:, behavior: nil, constraints: nil, decisions_made: nil)
      change_intent = ChangeIntent.create!(
        project: project_for_session!,
        chat_session: session,
        issue: issue_for_session,
        title: title.to_s.truncate(500),
        intent: intent.to_s,
        behavior: behavior.to_s.presence,
        constraints: constraints.to_s.presence,
        decisions_made: decisions_made.to_s.presence,
        status: "draft"
      )

      serialize(change_intent)
    end

    def resolve_confirmation(decision:, pending_result:)
      change_intent_id = pending_result["id"] || pending_result[:id]
      raise ArgumentError, "pending result must include an id" if change_intent_id.blank?

      TenantContext.with(account) do
        change_intent = policy_scope(ChangeIntent).where(project: project_for_session!).find(change_intent_id)
        authorize(change_intent, :update?, policy_class: ChangeIntentPolicy)

        case decision
        when :approve
          ChangeIntents::Activate.call(change_intent:)
        when :deny
          ChangeIntents::DiscardDraft.call(change_intent:)
        else
          raise ArgumentError, "decision must be approve or deny"
        end
      end
    rescue Pundit::NotAuthorizedError => error
      raise UnauthorizedError, error.message
    end

    private

    def project_for_session!
      session.project || raise(ArgumentError, "record_change_intent requires a chat session with a current project")
    end

    def issue_for_session
      issue_id = issue_id_for_session
      return unless issue_id.present?

      project_for_session!.issues.find_by(id: issue_id)
    end

    def issue_id_for_session
      session.page_context["issue_id"] ||
        session.metadata&.dig("issue_id") ||
        issue_id_from_page_path
    end

    def issue_id_from_page_path
      path = session.page_context["path"].to_s
      match = path.match(%r{\A/projects/\d+/issues/(\d+)(?:/|$)})
      match&.captures&.first
    end

    def serialize(change_intent)
      {
        id: change_intent.id,
        project_id: change_intent.project_id,
        chat_session_id: change_intent.chat_session_id,
        issue_id: change_intent.issue_id,
        title: change_intent.title,
        intent: change_intent.intent,
        behavior: change_intent.behavior,
        constraints: change_intent.constraints,
        decisions_made: change_intent.decisions_made,
        status: change_intent.status
      }
    end
  end
end
