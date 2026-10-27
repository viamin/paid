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

    # RDR-077 requires grants to finish or be explicitly revoked before the
    # old policy can take over again. It cannot interpret an active grant, so
    # allowing a project rollback would silently widen its execution scope.
    # @spec AUTOMATION-PHASES-014
    def assert_rollback_allowed!(project)
      return unless project.work_item_continuation_grants.active.exists?

      raise ActiveGrantsError, "Cannot disable automation phases while active continuation grants remain."
    end

    # Resolve a collection with tenant overrides preloaded, so checking many
    # project actors does not load each account and tenant setting separately.
    def enabled_project_ids(project_ids)
      Project.where(id: project_ids).includes(account: :tenant_setting)
        .filter_map { |project| project.id if enabled?(project) }
    end
  end
end
