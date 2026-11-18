# frozen_string_literal: true

module Automation
  # Serializes phase-model rollback with continuation-grant creation and
  # reconciles queued automatic work before legacy policy can resume.
  # @spec AUTOMATION-PHASES-014
  class PhaseRolloutRollback
    class ActiveGrantsError < StandardError
      attr_reader :project_ids, :grant_ids

      def initialize(grants)
        @project_ids = grants.map(&:project_id).uniq.sort
        @grant_ids = grants.map(&:id).sort
        super("Cannot disable automation phases while active continuation grants exist for projects #{project_ids.join(', ')} (grants #{grant_ids.join(', ')}). Finish or revoke the grants, then retry rollback.")
      end
    end

    class PendingReconciliationError < StandardError
      attr_reader :project_ids, :run_ids

      def initialize(runs)
        @project_ids = runs.map(&:project_id).uniq.sort
        @run_ids = runs.map(&:id).sort
        super("Cannot disable automation phases while queued runs still need reconciliation for projects #{project_ids.join(', ')} (runs #{run_ids.join(', ')}). Wait for the runs to finish or cancel them, then retry rollback.")
      end
    end

    def self.call(projects:, &block) = new(projects:).call(&block)

    def initialize(projects:)
      @project_ids = Array(projects).map { |project| project.is_a?(Project) ? project.id : project }.compact.uniq.sort
    end

    def call
      Project.transaction do
        projects = Project.where(id: project_ids).order(:id).lock.to_a
        grants = WorkItemContinuationGrant.active.where(project: projects).order(:id).to_a
        raise ActiveGrantsError, grants if grants.any?

        reconcile_queued_work(projects)
        pending_runs = pending_reconciliation_runs(projects)
        raise PendingReconciliationError, pending_runs if pending_runs.any?

        yield if block_given?
      end
    end

    private

    attr_reader :project_ids

    def reconcile_queued_work(projects)
      AgentRun.queued.where(project: projects).find_each do |run|
        AgentRuns::RecheckIssueEligibility.call(run)
      end
    end

    def pending_reconciliation_runs(projects)
      AgentRun.queued.where(project: projects).order(:id).lock.find_each.filter_map do |run|
        run if AgentRuns::RecheckIssueEligibility.withdrawn_phase_policy(run)
      end
    end
  end
end
