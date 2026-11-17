# frozen_string_literal: true

module Automation
  module Phases
    # RDR-077 Rollout Guard rollback protection: a project with an active
    # continuation grant can never silently revert to legacy interpretation,
    # because legacy policy cannot interpret scoped grants. Every supported
    # rollout mutation that can disable the phase model — project-scoped and
    # global FeatureFlags.disable! and the tenant-settings features override —
    # runs through this guard before the flag changes.
    #
    # A refusal raises FeatureFlags::RollbackBlockedError with an actionable,
    # inspectable reason and mutates nothing: the effective flag value, stored
    # settings, grants, and audit history are preserved. Once no affected
    # project holds an active grant, affected queued work is reconciled with
    # the dequeue recheck while the flag is still enabled — runs whose phase
    # authorization disappeared are cancelled and independently authorized
    # work is preserved — before the guarded mutation runs. The check, the
    # reconciliation, and the mutation share one transaction holding a
    # per-project advisory lock that grant creation also takes, so concurrent
    # grant creation serializes with the rollback instead of racing it.
    #
    # @spec AUTOMATION-PHASES-014
    class RollbackProtection
      FLAG = Automation::RolloutGuard::FLAG
      # Distinct int4 prefix for pg_advisory_xact_lock(namespace, project_id).
      LOCK_NAMESPACE = 770_077
      GRANT_SAMPLE_LIMIT = 5
      RECONCILE_BATCH_SIZE = 100

      class << self
        # Guards FeatureFlags.disable! for this flag. Yields inside the
        # protective transaction; raises RollbackBlockedError on refusal.
        def protect_disable(project: nil, actor: nil)
          affected = affected_projects_for_disable(project:, actor:)
          return yield if affected.empty?

          with_protection(affected) { yield }
        end

        # Guards a tenant-settings features mutation. Yields inside the
        # protective transaction; raises RollbackBlockedError on refusal.
        def protect_tenant_features(account:, features:)
          return yield unless disabling_tenant_override?(features)

          affected = account.projects.to_a.select do |project|
            rollout_enabled?(project) && holds_grants?(project)
          end
          return yield if affected.empty?

          with_protection(affected) { yield }
        end

        # Serializes grant creation (Automation::ManualStart::Plan#build_grant)
        # with a guarded rollback, closing the create-while-rolling-back race.
        def with_project_lock(project)
          ActiveRecord::Base.transaction do
            lock_projects(Array(project))
            yield
          end
        end

        private

        def affected_projects_for_disable(project:, actor:)
          target = project || actor
          return affected_global_projects unless target
          return [] unless target.is_a?(Project)
          return [] unless rollout_enabled?(target) && holds_grants?(target)
          return [] if tenant_override_keeps_enabled?(target)

          [ target ]
        end

        def affected_global_projects
          grant_project_ids = WorkItemContinuationGrant.distinct.pluck(:project_id)
          Project.where(id: grant_project_ids).includes(account: :tenant_setting).select do |project|
            rollout_enabled?(project) && !tenant_override_keeps_enabled?(project)
          end
        end

        def disabling_tenant_override?(features)
          return false unless features.is_a?(Hash)

          ActiveModel::Type::Boolean.new.cast(features[FLAG.to_s]) == false
        end

        def holds_grants?(project)
          WorkItemContinuationGrant.exists?(project_id: project.id)
        end

        def rollout_enabled?(project)
          FeatureFlags.enabled?(FLAG, project:)
        end

        def tenant_override_keeps_enabled?(project)
          features = project.account.tenant_setting&.features
          features.is_a?(Hash) && features[FLAG.to_s] == true
        end

        def with_protection(projects)
          ActiveRecord::Base.transaction do
            lock_projects(projects)

            active_grants = WorkItemContinuationGrant.active
              .where(project: projects).includes(:project).to_a
            raise active_grant_refusal(active_grants) if active_grants.any?

            pending = projects.flat_map { |project| reconcile_project!(project) }
            raise pending_reconciliation_refusal(pending) if pending.any?

            yield
          end
        end

        def lock_projects(projects)
          connection = ActiveRecord::Base.connection
          projects.map(&:id).sort.each do |project_id|
            connection.select_value(
              ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", LOCK_NAMESPACE, project_id ])
            )
          end
        end

        # Rechecks the project's affected queued work with the dequeue recheck
        # while the flag is still enabled, then returns the runs that remain
        # queued without phase authorization — the queue still owes its
        # standing to the revoked or finished grant, so legacy policy must not
        # take over yet.
        def reconcile_project!(project)
          affected_queued_runs(project).find_each(batch_size: RECONCILE_BATCH_SIZE) do |run|
            AgentRuns::RecheckIssueEligibility.call(run)
          end

          affected_queued_runs(project).select { |run| phase_unauthorized?(run) }
        end

        def affected_queued_runs(project)
          chain_ids = grant_chain_ids(project)
          return AgentRun.none if chain_ids.empty?

          AgentRun.where(project_id: project.id, issue_id: chain_ids, status: "queued")
        end

        # The work chains continuation grants cover: the granted work items,
        # their root issues, and the pull requests of those roots. Mirrors
        # Automation::CompleteContinuationGrants#chain_issue_ids.
        def grant_chain_ids(project)
          issue_ids = project.work_item_continuation_grants.distinct.pluck(:issue_id)
          return [] if issue_ids.empty?

          rows = Issue.where(id: issue_ids).pluck(:id, :is_pull_request, :parent_issue_id)
          parents = rows.filter_map { |_id, pull_request, parent| parent if pull_request && parent }
          roots = rows.map(&:first) | parents
          pull_request_ids = Issue.where(parent_issue_id: roots, is_pull_request: true).pluck(:id)

          roots | pull_request_ids
        end

        def phase_unauthorized?(run)
          return false unless automatic_authorization?(run)

          capability = AgentRuns::RecheckIssueEligibility::PHASE_CAPABILITIES[run.goal]
          return false if capability.nil?

          policy = Automation::EffectivePolicy.call(
            project: run.project.reload,
            phase: Automation::Phases.for_capability(capability),
            work_item: run,
            trigger: :automatic
          )
          !policy.permitted?
        end

        # The same automatic-authorization notion the dequeue recheck applies.
        def automatic_authorization?(run)
          run.automatic? || run.external_metadata["automatic_authorization"].present? ||
            (run.manual? && run.source_pull_request_number.present? && run.initiating_user_id.nil?)
        end

        def active_grant_refusal(grants)
          by_project = grants.group_by(&:project)
          summaries = by_project.map do |project, project_grants|
            "#{project.full_name}: #{project_grants.size} active continuation grant(s)"
          end
          message = "Cannot disable automation_phases yet — active continuation grants must " \
                    "finish or be revoked and affected queued work reconciled before rollback " \
                    "(#{summaries.join('; ')}). Finish the granted work or revoke the grants from " \
                    "the project's Automation phases settings, then retry the rollback."
          details = {
            flag: FLAG,
            projects: by_project.map do |project, project_grants|
              {
                id: project.id,
                full_name: project.full_name,
                active_grants: project_grants.size,
                grants: project_grants.first(GRANT_SAMPLE_LIMIT).map do |grant|
                  { id: grant.id, issue_id: grant.issue_id, start_phase: grant.start_phase, endpoint: grant.endpoint }
                end
              }
            end
          }
          log_refusal(reason: :active_grants, details:)
          FeatureFlags::RollbackBlockedError.new(message, details:)
        end

        def pending_reconciliation_refusal(pending_runs)
          by_project = pending_runs.group_by(&:project)
          summaries = by_project.map do |project, runs|
            "#{project.full_name}: agent run IDs #{runs.map(&:id).sort.join(', ')}"
          end
          message = "Cannot disable automation_phases yet — affected queued work is pending " \
                    "reconciliation: queued run(s) whose phase authorization disappeared could not " \
                    "be cancelled (#{summaries.join('; ')}). Retry the rollback after they are " \
                    "cancelled or independently re-authorized."
          details = {
            flag: FLAG,
            pending_runs: by_project.map do |project, runs|
              { project_id: project.id, full_name: project.full_name, agent_run_ids: runs.map(&:id).sort }
            end
          }
          log_refusal(reason: :pending_reconciliation, details:)
          FeatureFlags::RollbackBlockedError.new(message, details:)
        end

        def log_refusal(reason:, details:)
          Rails.logger.warn(
            message: "automation.phases.rollback_blocked",
            flag: FLAG,
            reason: reason,
            project_ids: project_ids_from(details)
          )
        end

        def project_ids_from(details)
          (details[:projects] || details[:pending_runs]).to_a.map { |entry| entry[:id] || entry[:project_id] }
        end
      end
    end
  end
end
