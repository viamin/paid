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
  end
end
