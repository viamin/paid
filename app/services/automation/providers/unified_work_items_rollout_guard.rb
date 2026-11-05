# frozen_string_literal: true

module Automation
  module Providers
    # RDR-079 guard for every new unified-work-item entry point. Existing
    # GitHub Issue behavior deliberately does not consult this guard.
    #
    # @spec UNIFIED-WORK-ITEMS-009
    module UnifiedWorkItemsRolloutGuard
      FLAG = :unified_work_items

      module_function

      def enabled?(project)
        FeatureFlags.enabled?(FLAG, project:)
      end
    end
  end
end
