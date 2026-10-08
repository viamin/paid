# frozen_string_literal: true

module PartialCloseouts
  # Bounded, restartable reconciliation for legacy partial closeouts that
  # pre-date the `partial-closeout-reconciliation-v1` workflow patch.
  #
  # The workflow activity (`Activities::ReconcilePartialCloseoutActivity`) only
  # ran on PR-producing runs that completed after the patch marker, so the
  # 2026-09-17 / 2026-09-22 / 2026-10-01 closeout audits against #3860,
  # #3861, #3871, #3930, and #4013 left empty `reconciliation` records and
  # no operator prerequisites. This sweep finds those runs, replays them
  # through the same deterministic machinery the workflow uses, and
  # surfaces the focused follow-ups + blocking prerequisites that the
  # activity would have produced on a fresh run.
  #
  # Idempotency is inherited from `PartialCloseouts::Reconcile`:
  # - the assessment is persisted on the run before reconciliation begins
  #   and reused across retries, so gap indices stay stable;
  # - the existing `prior_owner` and `recovered_remote_owner` recovery
  #   paths resume from a `creating` marker instead of filing again;
  # - the prerequisite notification publisher uses
  #   `Notifications::Publish` under a fixed source, so a second pass
  #   updates the existing notification instead of creating a new one.
  #
  # The sweep is deliberately read-only on `paid_state`: a legacy umbrella
  # stays open for its final audit even after every legacy gap is
  # reconciled. Closing the umbrella is the owner's intentional decision, not
  # the sweep's (#4187).
  # @spec PARTIAL-CLOSEOUT-012 @spec PARTIAL-CLOSEOUT-013
  # @spec PARTIAL-CLOSEOUT-014 @spec PARTIAL-CLOSEOUT-015
  class ReconcileLegacy
    # Terminal reconciliation statuses — a run in any of these states has
    # already produced durable owner / dependency / notification records,
    # so the sweep must skip it. `retryable_failure` is included so the
    # next pass resumes from the last durable state instead of restarting
    # from scratch (which would re-file owner issues from the assessment).
    TERMINAL_STATUSES = %w[reconciled awaiting_operator].freeze
    # The merge grace window used elsewhere to disambiguate PR numbers
    # that have not yet synced as local Issue rows. We inherit it so a
    # legacy sweep that runs an hour after a slug-deployed merge still
    # finds the originating run.
    PR_SYNC_GRACE_PERIOD = 1.hour

    Result = Struct.new(:scanned, :reconciled, :awaiting_operator, :retryable_failure, :skipped, keyword_init: true) do
      def to_h
        {
          scanned: scanned,
          reconciled: reconciled,
          awaiting_operator: awaiting_operator,
          retryable_failure: retryable_failure,
          skipped: skipped
        }
      end
    end

    def self.call(...) = new(...).call

    def initialize(account_id:)
      @account_id = account_id
    end

    def call
      scanned = 0
      reconciled = 0
      awaiting_operator = 0
      retryable_failure = 0
      skipped = 0

      TenantContext.with_system_access do
        candidate_runs.find_each do |agent_run|
          scanned += 1
          outcome = process_run(agent_run)
          case outcome
          when :reconciled then reconciled += 1
          when :awaiting_operator then awaiting_operator += 1
          when :retryable_failure then retryable_failure += 1
          when :skipped then skipped += 1
          end
        end
      end

      Result.new(
        scanned: scanned,
        reconciled: reconciled,
        awaiting_operator: awaiting_operator,
        retryable_failure: retryable_failure,
        skipped: skipped
      )
    end

    private

    attr_reader :account_id

    # Reads across tenant boundaries (`TenantContext.with_system_access`
    # wraps the caller) so the sweep can find candidates regardless of the
    # caller's account context, but the writes flow through the run's
    # project associations and are therefore scoped to the project.
    #
    # Candidate selection deliberately does NOT filter on
    # `reconciliation.status`. A run with a terminal status is still
    # scanned so callers can see how many runs were skipped without
    # re-running the analyzer; the in-process
    # `legacy_reconciliation_already_done?` gate applies the actual skip.
    def candidate_runs
      project_ids = Project.where(account_id: account_id).select(:id)
      AgentRun
        .where(project_id: project_ids, goal: "create_pr")
        .where.not(pull_request_number: nil)
        .where("agent_runs.completed_at IS NOT NULL")
        .where("agent_runs.completed_at < ?", PR_SYNC_GRACE_PERIOD.ago)
        .where("agent_runs.issue_id IS NOT NULL")
        .where(
          # Legacy targets: a run whose partial PR has authoritatively
          # linked back to its source issue (via `parent_issue_id` or via
          # the originating run's recorded `pull_request_number` URL join).
          # Mirrors the discipline in `Issues::CloseoutEvidence` so a
          # number-colliding upstream PR cannot fabricate a candidate.
          <<~SQL.squish
              EXISTS (
                  SELECT 1 FROM issues merged_prs
                  WHERE merged_prs.project_id = agent_runs.project_id
                    AND merged_prs.github_number = agent_runs.pull_request_number
                    AND merged_prs.is_pull_request = TRUE
                    AND merged_prs.pr_review_phase = 'merged'
                    AND (
                      merged_prs.parent_issue_id = agent_runs.issue_id
                      OR merged_prs.github_html_url = agent_runs.pull_request_url
                      OR (
                        merged_prs.github_html_url IS NULL
                        AND agent_runs.pull_request_url = CONCAT(
                          'https://github.com/',
                          (SELECT owner FROM projects WHERE id = agent_runs.project_id),
                          '/',
                          (SELECT repo FROM projects WHERE id = agent_runs.project_id),
                          '/pull/',
                          agent_runs.pull_request_number
                        )
                      )
                    )
                )
            SQL
        )
        .order(:id)
    end

    def process_run(agent_run)
      return :skipped if legacy_reconciliation_already_done?(agent_run)
      return :skipped if ineligible?(agent_run)

      Rails.logger.info(
        message: "partial_closeouts.legacy_reconcile_started",
        account_id: account_id,
        agent_run_id: agent_run.id,
        issue_id: agent_run.issue_id
      )

      assessment = Llm::AnalyzePartialCloseout.call(agent_run: agent_run)
      Reconcile.call(agent_run: agent_run, assessment: assessment)
      agent_run.reload
      status = agent_run.reconciliation.to_h.fetch("status", nil)

      case status
      when "reconciled" then :reconciled
      when "awaiting_operator" then :awaiting_operator
      when "retryable_failure"
        Rails.logger.warn(
          message: "partial_closeouts.legacy_reconcile_retryable_failure",
          account_id: account_id,
          agent_run_id: agent_run.id,
          error: agent_run.reconciliation.to_h["error"]
        )
        :retryable_failure
      else
        :skipped
      end
    rescue AgentHarness::Error => e
      Rails.logger.error(
        message: "partial_closeouts.legacy_reconcile_assessment_failed",
        account_id: account_id,
        agent_run_id: agent_run&.id,
        error_class: e.class.name,
        error: e.message
      )
      :retryable_failure
    rescue GithubClient::Error => e
      Rails.logger.error(
        message: "partial_closeouts.legacy_reconcile_github_failed",
        account_id: account_id,
        agent_run_id: agent_run&.id,
        error_class: e.class.name,
        error: e.message
      )
      :retryable_failure
    end

    # Two flavors of "already done":
    # 1. `reconciliation.status` is one of the TERMINAL_STATUSES (reconciled
    #    or awaiting_operator) — re-running would re-file the gap report.
    # 2. `reconciliation.status` is `retryable_failure` but a fresh
    #    `failed_at` is present and the run was touched within the recent
    #    past — repeat the call instead. We treat a stale `retryable_failure`
    #    (older than one day) as resumable so a worker that crashed before
    #    reaching GitHub does not strand a real attempt.
    def legacy_reconciliation_already_done?(agent_run)
      reconciliation = agent_run.reconciliation.to_h
      status = reconciliation["status"]
      return false if status.blank?
      return true if TERMINAL_STATUSES.include?(status)
      return false unless status == "retryable_failure"

      failed_at = reconciliation["failed_at"]
      return true if failed_at.blank?

      Time.parse(failed_at) >= 1.day.ago
    rescue ArgumentError
      false
    end

    # Issues parked in deliberate operator states (`needs_input`,
    # `manual_review`, paused flag, project pause) carry their own Inbox
    # lane and their own hold. The legacy sweep must never overwrite
    # those — the existing state is the operator's truth and the legacy
    # reconciliation runs alongside it.
    def ineligible?(agent_run)
      issue = agent_run.issue
      return true unless issue
      return true if issue.is_pull_request?
      return true unless issue.github_state == "open"

      paid_state = issue.paid_state.to_s
      paid_state.in?(%w[needs_input manual_review]) ||
        issue.paused? ||
        issue.project.paused?
    end
  end
end
