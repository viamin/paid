# frozen_string_literal: true

module Automation
  # RDR-077 Rollout Guard: the phase model is default-off and every decision
  # reads it through the project's feature-flag value. While off, the
  # pre-existing execution and Inbox policies stay in force.
  #
  # @spec AUTOMATION-PHASES-014
  module RolloutGuard
    FLAG = :automation_phases
    RollbackBlocked = Class.new(StandardError)

    module_function

    def enabled?(project)
      FeatureFlags.enabled?(FLAG, project:)
    end

    # A project cannot return to the legacy policy while an explicit grant is
    # still in force: the legacy policy has no way to interpret that grant.
    # The flag-management surface calls this before changing the flag state.
    # @spec AUTOMATION-PHASES-015
    def ensure_rollback_allowed!(project)
      active_grants = WorkItemContinuationGrant.active.where(project_id: project.id).count
      return if active_grants.zero?

      raise RollbackBlocked,
        "Cannot disable automation phases while #{active_grants} continuation " \
        "grant(s) are active; complete or revoke them first."
    end

    # Resolve a collection with tenant overrides preloaded, so checking many
    # project actors does not load each account and tenant setting separately.
    def enabled_project_ids(project_ids)
      Project.where(id: project_ids).includes(account: :tenant_setting)
        .filter_map { |project| project.id if enabled?(project) }
    end
  end
end
