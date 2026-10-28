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

    # Resolve a collection with tenant overrides preloaded, so checking many
    # project actors does not load each account and tenant setting separately.
    def enabled_project_ids(project_ids)
      Project.where(id: project_ids).includes(account: :tenant_setting)
        .filter_map { |project| project.id if enabled?(project) }
    end

    # A legacy-policy rollback cannot interpret continuation grants. Require an
    # operator to finish or revoke every grant before disabling the pilot.
    # @spec AUTOMATION-PHASES-014
    def ensure_disable_allowed!(project = nil)
      grants = WorkItemContinuationGrant.active
      grants = grants.where(project:) if project
      grant_ids = grants.limit(10).pluck(:id)
      return if grant_ids.empty?

      raise ActiveGrantsError,
        "Finish or revoke active continuation grants before rollback (grant ids: #{grant_ids.join(", ")})."
    end
  end
end
