# frozen_string_literal: true

module Automation
  # RDR-077 Rollout Guard: the phase model is default-off and every decision
  # reads it through the project's feature-flag value. While off, the
  # pre-existing execution and Inbox policies stay in force.
  #
  # @spec AUTOMATION-PHASES-014
  module RolloutGuard
    FLAG = :automation_phases
    RollbackBlockedError = Class.new(StandardError)

    module_function

    def enabled?(project)
      FeatureFlags.enabled?(FLAG, project:)
    end

    # The project-scoped flag-management path is the authorized rollback
    # surface. The legacy policy cannot interpret a live phase grant, so a
    # pilot must finish or revoke every grant before its flag is disabled.
    #
    # @spec AUTOMATION-PHASES-014
    def disable!(project:)
      project.with_lock do
        block_rollback_with_active_grants!(project)
        FeatureFlags.flipper[FLAG].disable(project)
      end
    end

    # Resolve a collection with tenant overrides preloaded, so checking many
    # project actors does not load each account and tenant setting separately.
    def enabled_project_ids(project_ids)
      Project.where(id: project_ids).includes(account: :tenant_setting)
        .filter_map { |project| project.id if enabled?(project) }
    end

    def block_rollback_with_active_grants!(project)
      return unless WorkItemContinuationGrant.active.where(project_id: project.id).exists?

      raise RollbackBlockedError,
        "Cannot disable automation phases while the project has active continuation grants; finish or revoke them first."
    end
    private_class_method :block_rollback_with_active_grants!
  end
end
