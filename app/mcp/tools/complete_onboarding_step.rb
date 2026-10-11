# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-008 ONBOARD-CHAT-010
  class CompleteOnboardingStep < BaseTool
    authorize :create?, ->(_args) { current_user.account }, policy_class: ApplicationPolicy

    def self.tool_name = "complete_onboarding_step"
    def self.write_operation? = true
    def self.description = "Mark an actually configured onboarding step complete after confirmation."

    def self.input_schema
      { type: "object", properties: { step: { type: "string", enum: OnboardingStep::STEPS }, metadata: { type: "object" }, confirmed: { type: "boolean" } }, required: %w[step confirmed] }
    end

    def perform(step:, confirmed:, metadata: {})
      raise ArgumentError, "Confirmation required: set confirmed=true to complete an onboarding step" unless confirmed

      verify_prerequisite!(step, metadata)
      result = Onboarding::CompleteStep.call(account:, step:, metadata:)
      result.attributes.slice("step", "status", "metadata", "completed_at")
    end

    private

    def verify_prerequisite!(step, metadata)
      verify_step_is_in_progress!(step)
      return configure_defaults!(metadata) if step == "configure_defaults"

      raise ArgumentError, "The #{step.humanize.downcase} setup has not been completed" unless prerequisite_met?(step)
    end

    def verify_step_is_in_progress!(step)
      onboarding_step = account.onboarding_steps.find_by!(step:)
      return if onboarding_step.in_progress?

      raise ArgumentError, "The #{step.humanize.downcase} onboarding step is not in progress"
    end

    def configure_defaults!(metadata)
      verify_minimum_setup!
      posture = metadata.fetch("operating_posture", nil)
      raise ArgumentError, "Choose an operating posture before completing setup" unless Onboarding::DefaultPosture::CHOICES.include?(posture)

      Onboarding::ApplyDefaultPosture.call(account:, actor: user, choice: posture)
      Onboarding::ProvisionDefaults.call(account:)
    end

    def verify_minimum_setup!
      required_steps = %w[account_profile github_token first_project]
      missing = required_steps.reject { |step| prerequisite_met?(step) }
      missing << "chat runner" unless runners.for_chat.exists?
      missing << "agent-run runner" unless runners.for_agent_runs.exists?
      return if missing.empty?

      raise ArgumentError, "Complete #{missing.join(", ")} before configuring defaults"
    end

    def prerequisite_met?(step)
      case step
      when "account_profile" then account.name.present?
      when "github_token" then account.github_tokens.active.exists? || account.github_installations.active.exists?
      when "first_project" then account.projects.exists?
      else false
      end
    end

    def runners
      current_user.runners.kept_only
    end
  end
end
