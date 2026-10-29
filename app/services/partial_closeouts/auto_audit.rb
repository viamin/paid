# frozen_string_literal: true

module PartialCloseouts
  # Schedules one report-only audit after terminal closeout evidence appears.
  # The issue lock covers the historical-attempt check and admission so a
  # completed or failed audit cannot be repeated by overlapping sweeps.
  # @spec PARTIAL-CLOSEOUT-037
  class AutoAudit
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
        return result(:assessment_current) unless Assessment.call(
          issue, evidence: status.evidence, technical_evidence: status.technical_evidence
        ).stale?
        return result(:already_audited) if prior_audit?(status.evidence.digest)

        request = Issues::RequestAcceptanceAudit.call(issue:, actor: issue.project.effective_owner, origin: :automatic)
        Result.new(agent_run: request.agent_run, code: request.code)
      end
    end

    private

    attr_reader :issue

    def prior_audit?(digest)
      IssueContinuationRequest.where(issue:, evidence_digest: digest)
        .where("evidence->>'continuation_mode' = ?", "acceptance_audit").exists?
    end

    def result(code) = Result.new(agent_run: nil, code:)
  end
end
