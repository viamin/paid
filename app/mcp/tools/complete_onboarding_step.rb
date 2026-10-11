# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-008
  class CompleteOnboardingStep < BaseTool
    authorize :update?, ->(_args) { current_user.account }, policy_class: ApplicationPolicy

    def self.tool_name = "complete_onboarding_step"
    def self.write_operation? = true
    def self.description = "Mark an actually configured onboarding step complete after confirmation."

    def self.input_schema
      { type: "object", properties: { step: { type: "string", enum: OnboardingStep::STEPS }, metadata: { type: "object" }, confirmed: { type: "boolean" } }, required: %w[step confirmed] }
    end

    def perform(step:, confirmed:, metadata: {})
      raise ArgumentError, "Confirmation required: set confirmed=true to complete an onboarding step" unless confirmed

      result = Onboarding::CompleteStep.call(account:, step:, metadata:)
      result.attributes.slice("step", "status", "metadata", "completed_at")
    end
  end
end
