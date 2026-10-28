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

    # @spec AUTOMATION-PHASES-014
    # A phase-policy rollback cannot safely make active grants uninterpretable.
    # Operators must let grants complete or revoke them before disabling the
    # project flag.
    def ensure_rollback_allowed!(project)
      return unless project.work_item_continuation_grants.active.exists?

      raise_active_grants_error
    end

    # @spec AUTOMATION-PHASES-014
    # A global flag disable can withdraw policy from any opted-in project.
    def ensure_global_rollback_allowed!
      return unless WorkItemContinuationGrant.active.exists?

      raise_active_grants_error
    end

    # @spec AUTOMATION-PHASES-014
    # Tenant configuration is the authorized pilot-management surface. Check
    # every currently enabled project before a tenant override withdraws the
    # phase policy for all of them.
    def ensure_account_rollback_allowed!(account:, proposed_features:)
      return unless disabling_automation_phases?(proposed_features)

      account.projects.find_each do |project|
        ensure_rollback_allowed!(project) if enabled?(project)
      end
    end

    # Resolve a collection with tenant overrides preloaded, so checking many
    # project actors does not load each account and tenant setting separately.
    def enabled_project_ids(project_ids)
      Project.where(id: project_ids).includes(account: :tenant_setting)
        .filter_map { |project| project.id if enabled?(project) }
    end

    def disabling_automation_phases?(features)
      features.is_a?(Hash) && features[FLAG.to_s] == false
    end

    def raise_active_grants_error
      raise ActiveGrantsError,
        "Cannot disable automation phases while active continuation grants remain. Revoke or complete them first."
    end
  end
end
