# frozen_string_literal: true

module Issues
  # Derives a revision-scoped automatic-admission hold from terminal run facts.
  # @spec NO-OUTPUT-ISSUE-009
  class NoProgressCreatePrHold
    MAX_RECORDED_RUN_IDS = 5
    REQUIRED_ATTEMPTS = 2
    NEXT_ACTION = "Update acceptance evidence or request an authorized retry."

    def self.held_issue_ids(project) = new(project:).held_issue_ids
    def self.diagnostic_for(issue) = new(project: issue.project).diagnostic_for(issue)

    def initialize(project:)
      @project = project
    end

    def held_issue_ids
      candidate_runs.group_by(&:issue_id).filter_map do |issue_id, runs|
        issue = issues_by_id[issue_id]
        issue_id if issue && current_runs(issue, runs).size >= REQUIRED_ATTEMPTS
      end
    end

    def diagnostic_for(issue)
      runs = current_runs(issue, candidate_runs.select { |run| run.issue_id == issue.id })
      return unless runs.size >= REQUIRED_ATTEMPTS

      { reason: "repeated_no_progress_create_pr", run_ids: runs.last(MAX_RECORDED_RUN_IDS).map(&:id), next_action: NEXT_ACTION }
    end

    private

    attr_reader :project

    def candidate_runs
      @candidate_runs ||= AgentRun.where(project:, goal: "create_pr", status: "completed", auto_pick: true)
        .where(pull_request_number: nil, result_commit_sha: nil).where("reconciliation ? 'no_progress'").order(:id).to_a
    end

    def issues_by_id
      @issues_by_id ||= project.issues.where(id: candidate_runs.map(&:issue_id)).index_by(&:id)
    end

    def current_runs(issue, runs)
      source_revision = PartialCloseouts::Assessment.source_revision_for(issue)
      intent_revision = PartialCloseouts::Assessment.intent_revision_for(issue)
      runs.select do |run|
        outcome = run.reconciliation.to_h.fetch("no_progress", {})
        outcome["outcome"] == "recommend_close" && outcome["source_revision"] == source_revision && outcome["intent_revision"] == intent_revision
      end
    end
  end
end
