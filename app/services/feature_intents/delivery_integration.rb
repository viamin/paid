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
      FeatureFlags.enabled?(FLAG, project:) && wiring_available? && review_enforcement_enabled?(project)
    end

    def self.wiring_available?
      ReleaseIssue.respond_to?(:call) &&
        RunAdmission.respond_to?(:call) &&
        CompleteForwardWork.respond_to?(:complete) &&
        IntentConformance::ScheduleReview.respond_to?(:call) &&
        IntentConformance::ReviewRun.respond_to?(:call)
    rescue NameError
      false
    end

    # The P11 prerequisite is the review that actually applies to
    # confidence-driven features: the conformance review dispatched against
    # each link's admitted baseline by ScheduleReview/ReviewRun, which runs
    # only under the enforcement pair. The approval-gated merge signal
    # (IntentConformance::Signal) is a deliberate no-op for these features,
    # so it can never stand in for this check, and shadow review is read-only
    # and never changes execution eligibility.
    def self.review_enforcement_enabled?(project)
      IntentConformance::Rollout.enforcement_enabled?(project)
    end
  end
end
