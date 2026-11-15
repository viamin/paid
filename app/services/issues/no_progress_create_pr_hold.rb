# frozen_string_literal: true

module Issues
  # Derives a revision-scoped automatic-admission hold from terminal run facts.
  # @spec NO-OUTPUT-ISSUE-009
  class NoProgressCreatePrHold
    MAX_RECORDED_RUN_IDS = 5
    REQUIRED_ATTEMPTS = 2
    NEXT_ACTION = "Update acceptance evidence or request an authorized retry."
    RELEASE_KEY = "no_progress_hold_release"

    def self.held_issue_ids(project) = new(project:).held_issue_ids
    def self.diagnostic_for(issue) = new(project: issue.project).diagnostic_for(issue)

    def self.release_fact_for(issue)
      return {} unless issue && diagnostic_for(issue)

      {
        RELEASE_KEY => {
          "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
          "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue)
        }
      }
    end

    def initialize(project:)
      @project = project
    end

    def held_issue_ids
      diagnostics_by_issue_id.keys
    end

    def diagnostics_by_issue_id
      @diagnostics_by_issue_id ||= begin
        source_revisions = PartialCloseouts::Assessment.source_revisions_for(issues_by_id.values)
        relevant_runs.group_by(&:issue_id).filter_map do |issue_id, runs|
          issue = issues_by_id[issue_id]
          diagnostic = diagnostic_for_runs(issue, runs, source_revisions.fetch(issue_id)) if issue
          [ issue_id, diagnostic ] if diagnostic
        end.to_h
      end
    end

    def diagnostic_for(issue)
      diagnostics_by_issue_id[issue.id]
    end

    private

    attr_reader :project

    def relevant_runs
      @relevant_runs ||= AgentRun.from("(#{latest_no_progress_runs.to_sql}) agent_runs")
        .where("sequence_position <= ?", REQUIRED_ATTEMPTS)
        .order(:issue_id, :id).to_a
    end

    # This projection runs on every automatic-admission check. Rank in SQL so
    # historical runs cannot grow the queue's in-memory work: only the two
    # attempts that can establish a hold after the latest delivery progress
    # are relevant to the current revision pair.
    def latest_no_progress_runs
      runs_after_latest_progress
        .where("agent_runs.reconciliation ? 'no_progress'")
        .select("agent_runs.*, ROW_NUMBER() OVER (PARTITION BY agent_runs.issue_id ORDER BY agent_runs.id DESC) AS sequence_position")
    end

    def runs_after_latest_progress
      candidate_runs.joins(<<~SQL.squish)
        LEFT JOIN (#{latest_progress_by_issue.to_sql}) latest_progress
          ON latest_progress.issue_id = agent_runs.issue_id
      SQL
        .where("agent_runs.id > COALESCE(latest_progress.latest_id, 0)")
    end

    def latest_progress_by_issue
      progress_runs.where(<<~SQL.squish)
        pull_request_number IS NOT NULL OR result_commit_sha IS NOT NULL
        OR reconciliation ? '#{RELEASE_KEY}'
      SQL
        .group(:issue_id).select("issue_id, MAX(id) AS latest_id")
    end

    def progress_runs
      AgentRun.where(project:, goal: "create_pr").where.not(issue_id: nil)
    end

    def candidate_runs
      progress_runs.where(status: "completed", auto_pick: true)
    end

    def issues_by_id
      @issues_by_id ||= project.issues.where(id: relevant_runs.map(&:issue_id)).index_by(&:id)
    end

    def diagnostic_for_runs(issue, runs, source_revision)
      runs = current_runs(issue, runs, source_revision)
      return unless runs.size >= REQUIRED_ATTEMPTS

      { reason: "repeated_no_progress_create_pr", run_ids: runs.last(MAX_RECORDED_RUN_IDS).map(&:id), next_action: NEXT_ACTION }
    end

    def current_runs(issue, runs, source_revision)
      intent_revision = PartialCloseouts::Assessment.intent_revision_for(issue)
      runs.select do |run|
        next if run.pull_request_number.present? || run.result_commit_sha.present?

        outcome = run.reconciliation.to_h.fetch("no_progress", {})
        outcome["outcome"] == "recommend_close" && outcome["source_revision"] == source_revision && outcome["intent_revision"] == intent_revision
      end
    end
  end
end
