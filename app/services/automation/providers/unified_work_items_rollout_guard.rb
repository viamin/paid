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

      # Account-scoped surfaces (the browser, assignment, mapping, trust, and
      # lifecycle services) have no single project actor. They establish
      # `Current.account` explicitly so the tenant-setting override resolves
      # against the correct account rather than an ambient request context.
      def enabled_for_account?(account)
        return false unless account

        Current.set(account:) { FeatureFlags.enabled?(FLAG) }
      end
    end
  end
end
