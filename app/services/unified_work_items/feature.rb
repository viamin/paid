# frozen_string_literal: true

module UnifiedWorkItems
  class FeatureDisabledError < StandardError; end

  module Feature
    module_function

    # @spec UNIFIED-WORK-ITEMS-009
    def ensure_enabled!(project:)
      return if FeatureFlags.enabled?(:unified_work_items, project:)

      raise FeatureDisabledError, "unified_work_items is disabled for this project"
    end
  end
end
