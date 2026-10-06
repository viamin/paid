# frozen_string_literal: true

module Issues
  class ResolveCloseout
    Result = Struct.new(:issue, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason:)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
    end

    def call # @spec PARTIAL-CLOSEOUT-006
      return failure(:invalid_reason, "A closeout reason is required.") if reason.blank?

      result = issue.with_lock { resolve }
      return result unless result.success?

      issue.project.account.account_activity_events.create!(action: "issue.closeout_resolved", actor:, subject: issue,
        metadata: { "reason" => reason, "evidence_digest" => issue.closeout_resolution_digest })
      Result.new(issue:)
    end

    private

    attr_reader :actor, :issue, :reason

    def resolve
      evidence = CloseoutEvidence.call(issue)
      return failure(:not_stalled, "This issue has no terminal closeout evidence.") unless evidence.present? && issue.github_state == "open"

      supersede_open_continuation
      issue.resolve_closeout!(actor:, evidence_digest: evidence.digest)
      Result.new(issue:)
    end

    # RequestContinuation takes this same issue lock while it atomically creates
    # its authorization and queued run. Closing that authorization before the
    # resolution means a queued run cannot be admitted after an operator has
    # declared the issue complete.
    def supersede_open_continuation
      request = IssueContinuationRequest.open_for_issue(issue)
      return unless request

      cancel_queued_continuation_runs(request)
      request.supersede!(reason: "Continuation superseded: issue resolved as complete.")
    end

    def cancel_queued_continuation_runs(request)
      request.agent_runs.where(status: "queued").find_each do |run|
        run.with_lock do
          next unless run.status == "queued" && run.temporal_workflow_id.nil?

          run.cancel!(error: "Continuation superseded: issue resolved as complete.")
        end
      end
    end

    def failure(code, message) = Result.new(code:, message:)
  end
end
