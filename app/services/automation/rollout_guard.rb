# frozen_string_literal: true

module Automation
  # RDR-077 Rollout Guard: the phase model is default-off and every decision
  # reads it through the project's feature-flag value. While off, the
  # pre-existing execution and Inbox policies stay in force.
  #
  # @spec AUTOMATION-PHASES-014
  module RolloutGuard
    FLAG = :automation_phases
    ActiveGrantsError = Class.new(StandardError)

    module_function

    def enabled?(project)
      FeatureFlags.enabled?(FLAG, project:)
    end

    # A legacy-policy rollback cannot safely interpret an outstanding grant.
    # Operators must first let it complete or explicitly revoke it.
    # @spec AUTOMATION-PHASES-014
    def ensure_rollback_allowed!(project)
      return unless project.work_item_continuation_grants.active.exists?

      raise ActiveGrantsError,
        "Cannot disable automation phases while the project has active continuation grants. " \
        "Complete or revoke them and reconcile queued work first."
    end

    # Resolve a collection with tenant overrides preloaded, so checking many
    # project actors does not load each account and tenant setting separately.
    def enabled_project_ids(project_ids)
      Project.where(id: project_ids).includes(account: :tenant_setting)
        .filter_map { |project| project.id if enabled?(project) }
    end
  end
end
