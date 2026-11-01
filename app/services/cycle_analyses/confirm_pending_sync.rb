# frozen_string_literal: true

module CycleAnalyses
  # Requeues confirmation after ordinary synchronization parses the declaration
  # source. Confirmation reads only the persisted graph and never writes GitHub.
  class ConfirmPendingSync
    def self.call(...) = new(...).call

    def initialize(project:, issue_numbers:)
      @project = project
      @issue_numbers = issue_numbers
    end

    # @spec AUTO-PICK-QUEUE-019
    def call
      pending_runs.each { |run| requeue_if_repaired_issue_was_synced(run) }
    end

    private

    attr_reader :issue_numbers, :project

    def pending_runs
      AgentRun.joins(:project).where(projects: { account_id: project.account_id },
        goal: AgentRun::CYCLE_ANALYSIS_GOAL, status: "completed")
        .where("verification_result -> ? -> 'repair' ->> 'status' = ?", RESULT_KEY, "pending_sync")
        .where("verification_result -> ? -> 'repair' -> 'details' ->> 'project_id' = ?", RESULT_KEY, project.id.to_s)
    end

    def requeue_if_repaired_issue_was_synced(run)
      return unless issue_numbers.include?(repaired_issue_number(run))

      run.with_lock do
        return unless pending_sync?(run)

        run.update!(status: "queued", started_at: nil, completed_at: nil)
        CycleAnalysisJob.perform_later(run.id)
      end
    end

    def repaired_issue_number(run)
      run.verification_result.dig(RESULT_KEY, "repair", "details", "issue_number")
    end

    def pending_sync?(run)
      run.status == "completed" && run.verification_result.dig(RESULT_KEY, "repair", "status") == "pending_sync"
    end
  end
end
