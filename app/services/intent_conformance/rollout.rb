# frozen_string_literal: true

module IntentConformance
  # Shared RDR-067 review rollout gate. Normal (enforcement) reviews require
  # the complete flag pair — the amendment flag alone must not silently start
  # reviews — and shadow evaluation is explicitly separate and read-only.
  # Confidence-delivery enrollment (RDR-071) reuses the enforcement check so
  # an enrolled feature always receives its policy-specific review; shadow
  # evaluation alone never changes execution eligibility
  # (@spec CONFIDENCE-DELIVERY-014).
  module Rollout
    module_function

    def enforcement_enabled?(project)
      FeatureFlags.enabled?(:approved_intent_amendments, project: project) &&
        FeatureFlags.enabled?(:intent_conformance_enforcement, project: project)
    end

    def shadow_or_enforcement_enabled?(project)
      FeatureFlags.enabled?(:intent_conformance_shadow_review, project: project) ||
        enforcement_enabled?(project)
    end
  end
end
