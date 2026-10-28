# frozen_string_literal: true

module Automation
  # RDR-077 Rollout Guard: the phase model is default-off and every decision
  # reads it through the project's feature-flag value. While off, the
  # pre-existing execution and Inbox policies stay in force.
  #
  # @spec AUTOMATION-PHASES-014
  module RolloutGuard
    FLAG = :automation_phases

    module_function

    def enabled?(project)
      FeatureFlags.enabled?(FLAG, project:)
    end

    # Resolve a collection with tenant overrides preloaded, so checking many
    # project actors does not load each account and tenant setting separately.
    def enabled_project_ids(project_ids)
      Project.where(id: project_ids).includes(account: :tenant_setting)
        .filter_map { |project| project.id if enabled?(project) }
    end

    # @spec AUTOMATION-PHASES-014
    # Tenant feature overrides are the authorized management surface for a
    # coordinated pilot. Do not let one setting change roll back a project
    # whose active grants only the guarded policy can interpret.
    def ensure_tenant_rollback_permitted!(account:, current_features:, requested_features:)
      return unless rollback_requested?(current_features, requested_features)
      return unless WorkItemContinuationGrant.active.where(project_id: account.projects.select(:id)).exists?

      raise FeatureFlags::RolloutBlockedError,
        "Cannot disable automation phases while this account has projects with active continuation grants. " \
        "Complete or revoke them and reconcile queued work before rollback."
    end

    def rollback_requested?(current_features, requested_features)
      current_features[FLAG.to_s] == true && requested_features[FLAG.to_s] == false
    end
  end
end
