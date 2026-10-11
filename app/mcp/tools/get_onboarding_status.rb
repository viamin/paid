# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-005 ONBOARD-CHAT-010
  class GetOnboardingStatus < BaseTool
    authorize :show?, ->(_args) { current_user.account }, policy_class: ApplicationPolicy

    def self.tool_name = "get_onboarding_status"
    def self.description = "Show onboarding steps and the current setup checklist."

    def perform
      { steps: steps, checklist: checklist, onboarding_completed: account.onboarding_completed_at.present? }
    end

    private

    def steps
      account.onboarding_steps.ordered.map { |step| step.attributes.slice("step", "status", "metadata", "completed_at") }
    end

    def checklist
      {
        chat_runner: runners.for_chat.exists?, github_credential: account.github_installations.active.exists? || account.github_tokens.active.exists?,
        project: account.projects.exists?, agent_run_runner: runners.for_agent_runs.exists?,
        tracker_configuration: policy_scope(TrackerConfiguration).exists?, profile_applied: account.onboarding_steps.find_by(step: "configure_defaults")&.completed?
      }
    end

    def runners
      policy_scope(Runner)
    end
  end
end
