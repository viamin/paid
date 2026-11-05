# frozen_string_literal: true

module UnifiedWorkItems
  # RDR-079 rollout guard for newly introduced provider-neutral entry points.
  # GitHub's existing issue contract remains available while this is disabled.
  # @spec UNIFIED-WORK-ITEMS-009
  module RolloutGuard
    FLAG = :unified_work_items
    FeatureDisabledError = Class.new(StandardError)

    module_function

    def enabled?(project)
      FeatureFlags.enabled?(FLAG, project:)
    end

    def require_enabled!(project)
      return if enabled?(project)

      raise FeatureDisabledError, "unified work items are not enabled for this project"
    end
  end
end
