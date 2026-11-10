# frozen_string_literal: true

module PartialCloseouts
  # Schedules one report-only audit after terminal closeout evidence appears.
  # The issue lock covers the historical-attempt check and admission so
  # overlapping sweeps cannot schedule the same retry.
  # @spec PARTIAL-CLOSEOUT-037 TRUSTED-MEASUREMENTS-006
  class AutoAudit
    MAX_ATTEMPTS = 3
    RETRY_DELAY = 30.minutes
    TRANSIENT_FAILURE_CATEGORIES = %w[transport_error timeout unsuccessful_response].freeze
    TRANSIENT_FAILURE_MESSAGES = [
      "Partial closeout assessment transport failed.",
      "Partial closeout assessment timed out.",
      "partial closeout assessment failed: transport returned an unsuccessful response."
    ].freeze
    Result = Data.define(:agent_run, :code) do
      def scheduled? = agent_run.present?
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return result(:automation_disabled) unless Issues::AutoPickProjectGate.call(issue.project)

      issue.with_lock do
        status = Issues::CloseoutStatus.call(issue)
        return result(:not_stalled) unless status.stalled?
        return result(:blocked) if status.blockers.any?
        assessment = Assessment.call(
          issue, evidence: status.evidence, technical_evidence: status.technical_evidence
        )
        return result(:assessment_current) unless assessment.stale?
        attempt_status = prior_attempt_status(assessment.current_source_revision)
        return result(attempt_status) if attempt_status

        request = Issues::RequestAcceptanceAudit.call(issue:, actor: issue.project.effective_owner, origin: :automatic)
        Result.new(agent_run: request.agent_run, code: request.code)
      end
    end

    private

    attr_reader :issue

    # @spec PARTIAL-CLOSEOUT-046
    def prior_attempt_status(source_revision)
      requests = acceptance_audit_requests(source_revision)
      intent_runs = audit_runs(requests, intent_revision: Assessment.intent_revision_for(issue))
      return :already_audited if intent_runs.any? { |run| !run.status.in?(%w[failed timeout]) || !transient_failure?(run) }
      # The retry budget belongs to the source revision — the evidence
      # generation — not to the approved-intent revision. Any issue-body edit
      # changes the intent revision, so a budget keyed to it would let one edit
      # multiply the audit spend for the same evidence generation (#5002
      # review).
      attempt_count = audit_attempt_count(requests)
      return :retry_exhausted if attempt_count >= MAX_ATTEMPTS
      # A changed approved intent may permit a further attempt against the same
      # source revision without resetting that revision's attempt budget.
      return if intent_runs.empty?

      delay = RETRY_DELAY * (2**(attempt_count - 1))
      return :retry_backoff if intent_runs.first.completed_at.blank? || intent_runs.first.completed_at > delay.ago

      nil
    end

    def acceptance_audit_requests(source_revision)
      IssueContinuationRequest.where(issue:)
        .where("evidence->>'source_revision' = ?", source_revision)
        .where("evidence->>'continuation_mode' = ?", "acceptance_audit")
    end

    # Every attempt against one evidence generation counts against the budget,
    # including attempts made under an earlier approved intent.
    def audit_attempt_count(requests)
      AgentRun.where(continuation_request_id: requests.select(:id)).count
    end

    # Attempts for one evidence generation, newest first. The approved-intent
    # filter also admits legacy audits that recorded their intent on the run's
    # persisted assessment instead of the request evidence.
    def audit_runs(requests, intent_revision: nil)
      scope = AgentRun.where(continuation_request_id: requests.select(:id)).joins(:continuation_request)
      scope = scope.where(intent_revision_sql, revision: intent_revision) if intent_revision
      scope.order(id: :desc).limit(MAX_ATTEMPTS).to_a
    end

    def intent_revision_sql
      "issue_continuation_requests.evidence->>'intent_revision' = :revision OR " \
        "(issue_continuation_requests.evidence->>'intent_revision' IS NULL AND " \
        "(agent_runs.reconciliation #>> '{assessment,intent_revision}' = :revision OR " \
        "agent_runs.reconciliation->'assessment' IS NULL))"
    end

    def transient_failure?(run)
      return true if run.status == "timeout"

      category = run.reconciliation.to_h.dig("acceptance_audit_failure", "category")
      return TRANSIENT_FAILURE_CATEGORIES.include?(category) if category.present?
      # A Temporal-level activity timeout never reaches the audit activity's
      # own rescue, so no typed category is recorded: the run is marked failed
      # with the runtime's timeout message instead. Treat that signature — and
      # an exhausted runner pool, which never reached a runner — as transient
      # so the revision still earns a bounded retry (#5002 review).
      return true if transport_interruption?(run)

      TRANSIENT_FAILURE_MESSAGES.any? { |message| run.error_message.to_s.start_with?(message) }
    end

    # Failure messages that name a transport-level interruption rather than a
    # permanent cause: the audit never obtained a usable answer.
    def transport_interruption?(run)
      return false unless run.status == "failed"

      message = run.error_message.to_s.downcase
      message.include?(AgentRun::ACTIVITY_TIMEOUT_MESSAGE.downcase) ||
        AgentRun::PROVIDER_UNAVAILABLE_KEYWORDS.any? { |keyword| message.include?(keyword.downcase) }
    end

    def result(code) = Result.new(agent_run: nil, code:)
  end
end
