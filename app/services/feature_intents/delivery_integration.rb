# frozen_string_literal: true

module FeatureIntents
  # The explicit rollout boundary for the integrated P10–P12 path. Project
  # enrollment remains a separate, authorized choice; this gate prevents that
  # choice from activating automatic release before admission, review, and
  # completion handling are deployed and verified together.
  # @spec CONFIDENCE-DELIVERY-014
  class DeliveryIntegration
    FLAG = :confidence_driven_delivery

    def self.available_for?(project)
      FeatureFlags.enabled?(FLAG, project:) && wiring_available?
    end

    def self.wiring_available?
      ReleaseIssue.respond_to?(:call) &&
        RunAdmission.respond_to?(:call) &&
        CompleteForwardWork.respond_to?(:complete) &&
        IntentConformance::Signal.respond_to?(:ok?)
    end
  end
end
