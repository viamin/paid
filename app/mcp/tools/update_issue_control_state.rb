# frozen_string_literal: true

module Tools
  # @spec LABEL-CONTROL-002
  class UpdateIssueControlState < BaseTool
    authorize :update?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    ACTIONS = Issues::UpdateControlState::ACTIONS

    def self.tool_name = "update_issue_control_state"
    def self.write_operation? = true
    def self.description = "Update Paid's local control state for an issue or pull request in ignored label mode. Requires confirmation."

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, issue_id: { type: "integer" },
          action: { type: "string", enum: ACTIONS },
          priority: { type: "string", enum: Issue::CONTROL_PRIORITIES },
          reason: { type: "string" }, confirmed: { type: "boolean" }
        }, required: %w[project_id issue_id action confirmed]
      }
    end

    def perform(project_id:, issue_id:, action:, confirmed: false, priority: nil, reason: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to update control state" unless confirmed

      issue = project_for(project_id).issues.find(issue_id)
      raise ArgumentError, "Local controls require ignored label mode" unless issue.local_control_state?

      Issues::UpdateControlState.call(issue:, actor: current_user, action:, priority:, reason:)
      serialize(issue.reload)
    end

    private

    def project_for(id) = policy_scope(Project).find(id)

    def serialize(issue)
      {
        id: issue.id, paused: issue.paused, pr_review_phase: issue.pr_review_phase,
        skip_auto_merge: issue.skip_auto_merge, hold_for_review: issue.hold_for_review,
        tdd_review_state: issue.tdd_review_state, control_priority: issue.control_priority,
        auto_pick_excluded_reason: issue.auto_pick_excluded_reason
      }
    end
  end
end
