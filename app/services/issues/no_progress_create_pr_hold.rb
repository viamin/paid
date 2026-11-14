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
      diagnostics_by_issue_id.keys
    end

    def diagnostics_by_issue_id
      @diagnostics_by_issue_id ||= relevant_runs.group_by(&:issue_id).filter_map do |issue_id, runs|
        issue = issues_by_id[issue_id]
        diagnostic = diagnostic_for_runs(issue, runs) if issue
        [ issue_id, diagnostic ] if diagnostic
      end.to_h
    end

    def diagnostic_for(issue)
      diagnostics_by_issue_id[issue.id]
    end

    private

    attr_reader :project

    def relevant_runs
      @relevant_runs ||= AgentRun.where(project:, goal: "create_pr", status: "completed", auto_pick: true)
        .where("reconciliation ? 'no_progress' OR pull_request_number IS NOT NULL OR result_commit_sha IS NOT NULL")
        .order(:id).to_a
    end

    def issues_by_id
      @issues_by_id ||= project.issues.where(id: relevant_runs.map(&:issue_id)).index_by(&:id)
    end

    def diagnostic_for_runs(issue, runs)
      runs = current_runs(issue, runs)
      return unless runs.size >= REQUIRED_ATTEMPTS

      { reason: "repeated_no_progress_create_pr", run_ids: runs.last(MAX_RECORDED_RUN_IDS).map(&:id), next_action: NEXT_ACTION }
    end

    def current_runs(issue, runs)
      source_revision = PartialCloseouts::Assessment.source_revision_for(issue)
      intent_revision = PartialCloseouts::Assessment.intent_revision_for(issue)
      runs.drop(progress_index(runs)).select do |run|
        next if run.pull_request_number.present? || run.result_commit_sha.present?

        outcome = run.reconciliation.to_h.fetch("no_progress", {})
        outcome["outcome"] == "recommend_close" && outcome["source_revision"] == source_revision && outcome["intent_revision"] == intent_revision
      end
    end

    def progress_index(runs)
      index = runs.rindex { |run| run.pull_request_number.present? || run.result_commit_sha.present? }
      index ? index + 1 : 0
    end
  end
end
