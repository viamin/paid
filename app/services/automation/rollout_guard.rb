# frozen_string_literal: true

module Automation
  # RDR-077 Rollout Guard: the phase model is default-off and every decision
  # reads it through the project's feature-flag value. While off, the
  # pre-existing execution and Inbox policies stay in force.
  #
  # @spec AUTOMATION-PHASES-014
  module RolloutGuard
    FLAG = :automation_phases
    ActiveGrantsPreventRollback = Class.new(StandardError)
    ProjectScopeRequired = Class.new(ArgumentError)

    module_function

    def enabled?(project)
      FeatureFlags.enabled?(FLAG, project:)
    end

    # Pilot activation is deliberately project-scoped. Broad activation skips
    # the coordinated mapping, configuration, storage, and Inbox validation
    # required by the RDR rollout guard.
    def ensure_enable_scope!(project:)
      return if project.is_a?(Project)

      raise ProjectScopeRequired,
        "automation_phases activation requires PROJECT_ID for an authorized pilot project"
    end

    # Old policy cannot interpret a live exception. Operators revoke or finish
    # grants and reconcile queued work before retrying the project rollback.
    # @spec AUTOMATION-PHASES-014
    def ensure_rollback_allowed!(project:)
      ensure_enable_scope!(project:) if project
      grants = project ? project.work_item_continuation_grants.active : WorkItemContinuationGrant.active
      active_grants = TenantContext.with_system_access { grants.exists? }
      return unless active_grants

      raise ActiveGrantsPreventRollback,
        "automation_phases rollback is blocked while an active continuation grant exists"
    end

    # Resolve a collection with tenant overrides preloaded, so checking many
    # project actors does not load each account and tenant setting separately.
    def enabled_project_ids(project_ids)
      Project.where(id: project_ids).includes(account: :tenant_setting)
        .filter_map { |project| project.id if enabled?(project) }
    end
  end
end
