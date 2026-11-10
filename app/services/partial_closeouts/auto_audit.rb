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
      requests = IssueContinuationRequest.where(issue:)
        .where("evidence->>'source_revision' = ?", source_revision)
        .where("evidence->>'continuation_mode' = ?", "acceptance_audit")
      intent_revision = Assessment.intent_revision_for(issue)
      runs = AgentRun.where(continuation_request_id: requests.select(:id))
        .joins(:continuation_request)
        .where("issue_continuation_requests.evidence->>'intent_revision' = :revision OR " \
          "(issue_continuation_requests.evidence->>'intent_revision' IS NULL AND " \
          "(agent_runs.reconciliation #>> '{assessment,intent_revision}' = :revision OR " \
          "agent_runs.reconciliation->'assessment' IS NULL))", revision: intent_revision)
        .order(id: :desc).limit(MAX_ATTEMPTS).to_a
      return if runs.empty?

      return :already_audited if runs.any? { |run| !run.status.in?(%w[failed timeout]) || !transient_failure?(run) }
      return :retry_exhausted if runs.size >= MAX_ATTEMPTS
      delay = RETRY_DELAY * (2**(runs.size - 1))
      return :retry_backoff if runs.first.completed_at.blank? || runs.first.completed_at > delay.ago

      nil
    end

    def transient_failure?(run)
      return true if run.status == "timeout"

      category = run.reconciliation.to_h.dig("acceptance_audit_failure", "category")
      return TRANSIENT_FAILURE_CATEGORIES.include?(category) if category.present?

      TRANSIENT_FAILURE_MESSAGES.any? { |message| run.error_message.to_s.start_with?(message) }
    end

    def result(code) = Result.new(agent_run: nil, code:)
  end
end
