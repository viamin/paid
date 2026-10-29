# frozen_string_literal: true

module Issues
  class ResolveCloseout
    Result = Struct.new(:issue, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    # The legacy pane submitted this canned sentence as a hidden field. The
    # rationale is now operator-authored, so an unchanged canned payload is
    # refused structurally — no semantic judgment is made about the reason's
    # content (#4189).
    LEGACY_CANNED_REASON = /\AOperator attests the recorded closeout evidence completes #\d+\.\z/

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason:, client: nil)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
      @client = client
    end

    def call # @spec PARTIAL-CLOSEOUT-006 PARTIAL-CLOSEOUT-037
      return failure(:invalid_reason, "A closeout reason is required.") if reason.blank?
      return failure(:generic_reason, "Enter a specific completion rationale that references the recorded evidence " \
        "(for example which merged PRs or no-code declaration cover each acceptance criterion).") if canned_reason?

      result = issue.with_lock { resolve }
      return result unless result.success?

      issue.project.account.account_activity_events.create!(action: "issue.closeout_resolved", actor:, subject: issue,
        metadata: { "reason" => reason, "evidence_digest" => issue.closeout_resolution_digest })
      Result.new(issue:)
    end

    private

    attr_reader :actor, :issue, :reason

    def canned_reason?
      reason.match?(LEGACY_CANNED_REASON)
    end

    def resolve
      evidence = CloseoutEvidence.call(issue)
      return failure(:not_stalled, "This issue has no terminal closeout evidence.") unless evidence.present? && issue.github_state == "open"
      if issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE
        return failure(:scanner_managed, "This record has no GitHub Issue to close. Wait for or repair the next " \
          "authoritative code-scanning snapshot so scanner reconciliation can observe source closure.")
      end
      return failure(:audit_pending, "A current acceptance audit is required before GitHub can be closed.") unless accepted_assessment?
      return failure(:open_prerequisites, "Current prerequisites or required verification still block GitHub closure.") if closure_blocked?
      remote_state = remote_github_state
      return failure(:github_unavailable, "GitHub closure could not be verified; retry Close on GitHub from this Inbox item.") unless remote_state.in?(%w[open closed])

      if remote_state == "open"
        updated = client.update_issue(issue.project.full_name, issue.github_number, state: "closed", state_reason: "completed")
        return failure(:github_unavailable, "GitHub did not confirm closure; retry Close on GitHub from this Inbox item.") unless github_closed?(updated)
      end

      supersede_open_continuation
      issue.resolve_closeout!(actor:, evidence_digest: evidence.digest)
      Result.new(issue:)
    rescue GithubClient::Error
      failure(:github_failed, "GitHub closure failed; retry Close on GitHub from this Inbox item.")
    end

    def accepted_assessment?
      assessment = PartialCloseouts::Assessment.call(issue)
      assessment.closeout_state == "accepted_awaiting_github_closure" &&
        PartialCloseouts::SourceClosureDisposition.call(issue:, assessment: assessment.assessment)["disposition"] == PartialCloseouts::SourceClosureDisposition::CLOSE
    end

    def closure_blocked?
      status = CloseoutStatus.call(issue)
      status.blockers.any? { |blocker| blocker.code.in?(%i[unmet_prerequisites scanner_verification_pending scanner_verification_retryable scanner_verification_failed open_native_children human_prerequisite_notification]) }
    end

    def remote_github_state
      remote = client.issue(issue.project.full_name, issue.github_number)
      remote.state if remote.respond_to?(:state)
    end

    def github_closed?(remote)
      remote.respond_to?(:state) && remote.state == "closed"
    end

    def client
      @client ||= issue.project.client || raise(GithubClient::Error, "No GitHub client is configured")
    end

    # RequestContinuation takes this same issue lock while it atomically creates
    # its authorization and queued run. Closing that authorization before the
    # local resolution means a queued run cannot be admitted after GitHub has
    # confirmed that the issue is complete.
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
