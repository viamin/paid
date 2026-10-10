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
  # - the assessment is the deterministic input for replay — it is persisted
  #   on the run before `Reconcile` is invoked and reused across retries,
  #   so gap indices stay stable. `Reconcile` keys `owner_marker(index)`,
  #   `prior_owner(index)`, and `creation_was_recorded?(index, marker)` by
  #   gap array index; a reordered assessment would otherwise attach the
  #   owner created for the old index 0 to whichever gap now sits at index
  #   0, producing an incorrect dependency. Mirroring
  #   `Activities::ReconcilePartialCloseoutActivity#persisted_assessment`
  #   keeps the legacy path replay-safe across GitHub failures;
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
  # @spec PARTIAL-CLOSEOUT-018 @spec PARTIAL-CLOSEOUT-019
  # @spec PARTIAL-CLOSEOUT-020 @spec PARTIAL-CLOSEOUT-021
  class ReconcileLegacy
    # Terminal reconciliation statuses — a run in any of these states has
    # already produced durable owner / dependency / notification records,
    # so the sweep must skip it. `retryable_failure` is handled separately
    # by the one-day retry gate in `legacy_reconciliation_already_done?`:
    # a fresh failure skips this pass, a stale one resumes from the last
    # durable state instead of restarting from scratch (which would re-file
    # owner issues from the assessment).
    TERMINAL_STATUSES = %w[reconciled awaiting_operator].freeze
    # The merge grace window used elsewhere to disambiguate PR numbers
    # that have not yet synced as local Issue rows. We inherit it so a
    # legacy sweep that runs an hour after a slug-deployed merge still
    # finds the originating run.
    PR_SYNC_GRACE_PERIOD = 1.hour
    # An account's merged `create_pr` history is unbounded, and every
    # candidate that reaches `process_run` costs an `Llm::AnalyzePartialCloseout`
    # call. This caps a single invocation's candidate window; pass the
    # previous `Result#next_cursor` as `after_id:` to resume (#4191 review).
    DEFAULT_BATCH_SIZE = 200
    # Legacy targets: a run whose partial PR has authoritatively linked back
    # to its source issue (via `parent_issue_id` or via the originating
    # run's recorded `pull_request_number` URL join). Mirrors the discipline
    # in `Issues::CloseoutEvidence` so a number-colliding upstream PR cannot
    # fabricate a candidate.
    MERGED_LINK_CONDITION = <<~SQL.squish
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
    # Only an issue's latest PR-producing attempt carries the authoritative
    # closeout state. A superseded earlier partial closeout must never be
    # assessed — its evidence is stale once a later `create_pr` attempt
    # exists for the same issue, or the sweep would file dependencies and
    # operator notifications the later attempt already replaced — mirroring
    # the MAX(id)-per-issue keying in
    # `DefaultCandidateSource#partial_closeout_reaudit_issue_ids`
    # (PARTIAL-CLOSEOUT-021 / #4191 review).
    LATEST_PR_ATTEMPT_CONDITION = <<~SQL.squish
      NOT EXISTS (
          SELECT 1 FROM agent_runs later_attempts
          WHERE later_attempts.issue_id = agent_runs.issue_id
            AND later_attempts.goal = 'create_pr'
            AND later_attempts.pull_request_number IS NOT NULL
            AND later_attempts.id > agent_runs.id
        )
    SQL

    Result = Struct.new(
      :scanned, :reconciled, :awaiting_operator, :retryable_failure, :skipped, :next_cursor, :lock_held,
      keyword_init: true
    ) do
      def initialize(lock_held: false, **attributes)
        super(**attributes, lock_held:)
      end

      def to_h
        {
          scanned: scanned,
          reconciled: reconciled,
          awaiting_operator: awaiting_operator,
          retryable_failure: retryable_failure,
          skipped: skipped,
          next_cursor: next_cursor,
          lock_held: lock_held
        }
      end
    end

    # Read-only preview row: no LLM or GitHub call has happened yet, so
    # there is nothing to report beyond which run/issue a real `call`
    # would pick up.
    CandidateRun = Struct.new(:id, :issue_id, keyword_init: true)

    # Namespaces this sweep's advisory locks apart from the other
    # pg_advisory_lock callers in app/services (each picks its own
    # constant; see Containers::PoolManager, Previews::Lifecycle, etc.).
    ADVISORY_LOCK_NAMESPACE = 1_357_180_006
    ADVISORY_TRY_LOCK_SQL = "SELECT pg_try_advisory_lock(?, ?)".freeze
    ADVISORY_UNLOCK_SQL = "SELECT pg_advisory_unlock(?, ?)".freeze

    def self.call(...) = new(...).call

    def self.preview(...) = new(...).preview

    def initialize(account_id:, batch_size: DEFAULT_BATCH_SIZE, after_id: nil)
      unless batch_size.is_a?(Integer) && batch_size.positive?
        raise ArgumentError, "batch_size must be a positive integer, got #{batch_size.inspect}"
      end

      @account_id = account_id
      @batch_size = batch_size
      @after_id = after_id
    end

    # The design doc blesses invoking this sweep from both the operator
    # console / MCP surface and the rake task, so two overlapping calls for
    # the same account are an expected operational shape, not a misuse.
    # Without serialization both processes would see the same blank
    # `legacy_reconciliation_already_done?` state, both invoke the LLM, and
    # `Reconcile#create_owner!` would observe `creation_was_recorded?` as
    # false in both — the marker machinery dedupes sequential retries, not
    # concurrent ones, so two owner issues with the same marker would land
    # on GitHub. `pg_try_advisory_lock` keyed on account_id lets independent
    # accounts sweep concurrently while serializing same-account overlap;
    # a caller that finds the lock held gets a zero-progress Result back
    # (mirrors ProcessRunQueueJob's try-lock-and-skip, #4191 review).
    def call # @spec PARTIAL-CLOSEOUT-021
      unless try_lock!
        Rails.logger.info(message: "partial_closeouts.legacy_reconcile_lock_held", account_id: account_id)
        return Result.new(scanned: 0, reconciled: 0, awaiting_operator: 0, retryable_failure: 0, skipped: 0, next_cursor: after_id, lock_held: true)
      end

      begin
        scanned = 0
        reconciled = 0
        awaiting_operator = 0
        retryable_failure = 0
        skipped = 0
        next_cursor = nil

        TenantContext.with_system_access do
          candidate_runs.find_each do |agent_run|
            scanned += 1
            next_cursor = agent_run.id
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
          skipped: skipped,
          next_cursor: next_cursor,
          lock_held: false
        )
      ensure
        unlock!
      end
    end

    # Read-only scan — no LLM call, no `Reconcile`, no GitHub writes. Lets
    # an operator see exactly which runs `call` would process before opting
    # into a sweep that files owner issues and rewrites issue bodies
    # (#4191 review).
    def preview
      TenantContext.with_system_access do
        candidate_runs.order(:id).pluck(:id, :issue_id).map { |id, issue_id| CandidateRun.new(id: id, issue_id: issue_id) }
      end
    end

    private

    def try_lock!
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ ADVISORY_TRY_LOCK_SQL, ADVISORY_LOCK_NAMESPACE, account_id ])
      )
    end

    def unlock!
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([ ADVISORY_UNLOCK_SQL, ADVISORY_LOCK_NAMESPACE, account_id ])
      )
    end

    attr_reader :account_id, :batch_size, :after_id

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
    # Selection DOES restrict to each issue's latest PR-producing run
    # (`LATEST_PR_ATTEMPT_CONDITION`): a superseded earlier attempt is
    # excluded before the reconciliation-state checks, not skipped by
    # them, so stale evidence can never be assessed.
    #
    # `after_id` + `limit(batch_size)` bound a single invocation's LLM cost
    # and runtime to a fixed-size window instead of the account's entire
    # merged `create_pr` history (#4191 review). The cursor is monotonic
    # because `#call` consumes this scope via `find_each`, which batches in
    # ascending primary-key order by default: each page starts strictly
    # after the highest `id` the previous page scanned (`Result#next_cursor`),
    # so a caller that loops `call(account_id:, after_id: result.next_cursor)`
    # until `scanned < batch_size` is guaranteed to traverse the whole
    # backlog exactly once, regardless of how many rows in a given page turn
    # out to be already-terminal or otherwise ineligible. Deliberately no
    # explicit `.order(:id)` here: `find_each`/`in_batches` on Rails 8.1 warns
    # and discards any scoped order on the relation, so an explicit order
    # would only produce a spurious warning on every `#call` while matching
    # the default batch order anyway. `#preview` applies `.order(:id)`
    # itself for its deterministic dry-run listing, since it plucks directly
    # instead of batching (#4191 review).
    def candidate_runs
      project_ids = Project.where(account_id: account_id).select(:id)
      AgentRun
        .where(project_id: project_ids, goal: "create_pr")
        .where.not(pull_request_number: nil)
        .where("agent_runs.completed_at IS NOT NULL")
        .where("agent_runs.completed_at < ?", PR_SYNC_GRACE_PERIOD.ago)
        .where("agent_runs.issue_id IS NOT NULL")
        .then { |scope| after_id ? scope.where("agent_runs.id > ?", after_id) : scope }
        .where(MERGED_LINK_CONDITION)
        .where(LATEST_PR_ATTEMPT_CONDITION)
        .limit(batch_size)
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

      assessment = persisted_assessment(agent_run)
      Reconcile.call(agent_run: agent_run, assessment: assessment)
      Advance.call(agent_run: agent_run, assessment: assessment)
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
      persist_retryable_failure!(agent_run, e)
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
    rescue StandardError => e
      Rails.logger.error(
        message: "partial_closeouts.legacy_reconcile_failed",
        account_id: account_id,
        agent_run_id: agent_run&.id,
        error_class: e.class.name,
        error: e.message
      )
      # Non-GitHub failures are deterministic (e.g. an assessment whose
      # owner_issue_number does not resolve to an open issue and whose title
      # is blank — `Reconcile.create_owner!` raises `ArgumentError` after the
      # assessment already passed `Llm::AnalyzePartialCloseout#owner_resolvable?`).
      # Discard the persisted assessment so the next pass regenerates
      # instead of replaying the same deterministic failure forever; GitHub
      # failures above keep it for the marker-based recovery path
      # (PARTIAL-CLOSEOUT-020 / #4187 review).
      persist_retryable_failure!(agent_run, e)
      :retryable_failure
    end

    # `Reconcile#call` records only its own `GithubClient::Error`s, so every
    # failure rescued here must persist the failure itself: an unpersisted
    # failure leaves an empty reconciliation record, and the next invocation
    # would immediately re-invoke the LLM instead of honoring the one-day
    # retry gate in `legacy_reconciliation_already_done?` (#4191 review).
    def persist_retryable_failure!(agent_run, error)
      return unless agent_run

      # Only discard the assessment when no index-keyed gap state survives:
      # `prior_owner` and `local_owner_with_marker` key owners by gap index,
      # so a regenerated (possibly reordered) assessment paired with surviving
      # gaps state attaches the old gap's owner to whichever gap now sits at
      # that index. When gap state exists, keep the assessment so the retry
      # replays the same indices; a deterministic re-failure is bounded to
      # this one run and visible via `retryable_failure`, unlike a silent
      # mislink (#4191 review).
      reconciliation = agent_run.reconciliation
      reconciliation = reconciliation.except("assessment") if reconciliation["gaps"].blank?
      agent_run.update!(
        reconciliation: reconciliation.merge(
          "status" => "retryable_failure", "error" => error.message, "failed_at" => Time.current.iso8601
        )
      )
    end

    # Two flavors of "already done":
    # 1. `reconciliation.status` is one of the TERMINAL_STATUSES (reconciled
    #    or awaiting_operator) — re-running would re-file the gap report.
    # 2. `reconciliation.status` is `retryable_failure` with a fresh
    #    `failed_at` (within one day) — the one-day retry gate holds and
    #    the sweep skips the run this pass. A stale `retryable_failure`
    #    (older than one day) is resumable, so a worker that crashed
    #    before reaching GitHub does not strand a real attempt.
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

    # The LLM is the only non-deterministic step in the sweep; persisting its
    # output before invoking `Reconcile` is what keeps retries replay-safe.
    # `Reconcile.create_owner!` keys `owner_marker(index)` and
    # `creation_was_recorded?(index, marker)` by gap array index, so a
    # reordered re-invocation could attach the owner created for the old
    # index 0 to whichever gap now sits at index 0 — or overwrite an in-flight
    # `creating` gap state with the new assessment's gap at the same key
    # (PARTIAL-CLOSEOUT-020). Mirroring
    # `Activities::ReconcilePartialCloseoutActivity#persisted_assessment`
    # means a GitHub failure leaves the first assessment durable, and the
    # next pass (after the 1-day `retryable_failure` window) replays the same
    # gap set through the marker-based recovery path (#4187).
    def persisted_assessment(agent_run)
      agent_run.reconciliation["assessment"] || Llm::AnalyzePartialCloseout.call(agent_run: agent_run).then do |result|
        Assessment.snapshot(agent_run, result).tap do |assessment|
          agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => assessment))
        end
      end
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
