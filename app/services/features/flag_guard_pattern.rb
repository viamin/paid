# frozen_string_literal: true

module Features
  # Decides whether the paid Rails feature-flag rollout-guard pattern
  # (`FeatureFlags::DEFINITIONS` + `FeatureFlags.enabled?`) is meaningful for a
  # project's codebase.
  #
  # Ruby or Rails alone does not establish that a repository implements this
  # Paid-specific API. Requiring those artifacts without scan evidence would
  # force Paid's flag system into a foreign codebase (#4172), so the RDR output
  # contract and agent prompts demand them only after the repository profile
  # confirms the exact API. Projects without that evidence use their own flag
  # or configuration mechanism.
  # @spec RDR-ROLLOUT-GUARD-003
  # @spec RDR-ROLLOUT-GUARD-004
  module FlagGuardPattern
    class << self
      def applicable?(project)
        return false unless project.respond_to?(:uses_feature_flags_pattern?)

        project.uses_feature_flags_pattern? == true
      end
    end
  end
end
