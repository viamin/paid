# frozen_string_literal: true

module AgentRuns
  # RDR-032 hardening: recheck a queued run's issue eligibility at dequeue
  # time. Eager queue seeding creates a queued run the moment an issue
  # becomes eligible, but the issue can lose eligibility before the
  # scheduler claims the run — a skip label added, paid_state entering a
  # skip state, a new blocking dependency, the issue closed/completed, an
  # untrusted creator, etc.
  #
  # Those stale queued runs would otherwise hold a unique-active-run slot
  # and pollute the dashboard queue preview forever. Cancel them here so
  # the re-enqueue hooks (sync, paid_state change, dependency close) can
  # recreate the run when the issue becomes eligible again.
  #
  # Only eagerly-seeded auto-pick runs tied to an issue are rechecked:
  # manual runs are an explicit operator request, create_issue / no-issue
  # runs have nothing to recheck, and review goals are PR-scoped with
  # their own retry/limit handling.
  class RecheckIssueEligibility
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run)
      @agent_run = agent_run
    end

    # Returns true when the run was cancelled because its issue is no
    # longer eligible; false when the run should proceed normally.
    def call
      return false unless recheck_applicable?
      return false if issue_still_eligible?

      cancel_run
    end

    private

    attr_reader :agent_run

    def recheck_applicable?
      agent_run.auto_pick? &&
        agent_run.issue_id.present? &&
        !agent_run.review_goal?
    end

    def issue_still_eligible?
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_for_dequeue?(
          agent_run.project,
          agent_run.issue_id,
          excluding_run_id: agent_run.id
        )
    end

    # Cancel only unclaimed queued runs — a claimed/running run is
    # mid-flight and owned by the normal lifecycle. Re-check under the row
    # lock (mirrors Issue#cancel_orphaned_queued_runs) so a run claimed by
    # ProcessRunQueueJob between the eligibility check and here is not
    # marked cancelled while its workflow starts.
    def cancel_run
      reason = "Issue no longer eligible at dequeue (RDR-032 recheck); " \
               "it will be re-seeded when eligible again"

      cancelled = agent_run.with_lock do
        next false unless agent_run.status == "queued" && agent_run.temporal_workflow_id.nil?

        agent_run.cancel!(error: reason)
      end

      log_cancelled if cancelled
      cancelled
    rescue => e
      log_failure(e)
      false
    end

    def log_cancelled
      Rails.logger.info(
        message: "process_run_queue.cancelled_ineligible_issue",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id,
        goal: agent_run.goal
      )
    end

    def log_failure(error)
      Rails.logger.error(
        message: "process_run_queue.recheck_eligibility_failed",
        agent_run_id: agent_run.id,
        issue_id: agent_run.issue_id,
        error: error.message
      )
    end
  end
end
