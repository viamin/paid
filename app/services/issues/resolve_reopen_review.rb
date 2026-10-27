# frozen_string_literal: true

module Issues
  # Records the operator's intent-validation decision for a reopened issue
  # (#4640).
  #
  # The reopen gate (`Issue#reopen_review_pending?`) exists because a reopened
  # issue invalidates the previous closure decision. This service is the one
  # supported way to resolve that gate: the decision is explicit, carries the
  # operator's own reason, and is bound to the issue revision the operator
  # reviewed, so a decision made against a different scope cannot be applied.
  #
  # The decision releases the reopen gate only. Other holds — an unresolved
  # dependency, a queued run — keep the issue parked, so an acknowledgment can
  # never waive them.
  #
  # @spec MANUAL-REVIEW-RECOVERY-002
  class ResolveReopenReview
    Result = Struct.new(:issue, :decision, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    VALID = "intent_valid"
    SUPERSEDED = "intent_superseded"
    DECISIONS = [ VALID, SUPERSEDED ].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, decision:, reason:, revision:)
      @issue = issue
      @actor = actor
      @decision = decision.to_s
      @reason = reason.to_s.strip
      @revision = revision.to_s
    end

    def call
      return failure(:not_authorized, "You are not authorized to review this issue.") unless authorized?
      return failure(:not_in_reopen_review, "This issue is not waiting for a reopen review.") unless reopen_review_parked?
      return failure(:already_decided, "This reopen review was already decided.") if issue.reopen_review_decided?
      return failure(:invalid_decision, "Choose whether the original intent still applies.") unless DECISIONS.include?(decision)
      return failure(:invalid_reason, "A reopen-review reason is required.") if reason.blank?
      return failure(:invalid_revision, "The reviewed issue revision is required.") if revision.blank?
      return failure(:stale_revision, stale_revision_message) unless current_revision == revision

      record_decision
    end

    private

    attr_reader :actor, :decision, :issue, :reason, :revision

    def authorized?
      return false if actor.blank?

      account_id = issue.project&.account_id
      account_id.present? && account_id == actor.account_id
    end

    def reopen_review_parked?
      issue.paid_state == "manual_review" &&
        issue.manual_review_reason == Issue::REOPEN_REVIEW_REQUIRED_REASON
    end

    def current_revision
      Issue.reopen_review_revision_for(title: issue.title, body: issue.body)
    end

    def stale_revision_message
      "This issue changed since the review was opened. Reload the Inbox and validate the current scope."
    end

    def record_decision
      issue.with_lock do
        issue.reload
        return failure(:already_decided, "This reopen review was already decided.") if issue.reopen_review_decided?

        issue.update!(
          reopen_review_decision: decision,
          reopen_review_reason: reason,
          reopen_review_decided_at: Time.current,
          reopen_review_decided_by_id: actor.id,
          reopen_review_revision: revision
        )
      end

      keep_remaining_holds_parked
      record_audit_event
      Result.new(issue:, decision:)
    end

    # A dependency that still blocks the issue keeps it parked; the reopen
    # decision never waives it. The parking reason is rewritten so the Inbox
    # classifies the remaining hold instead of the resolved reopen review.
    def keep_remaining_holds_parked
      return if issue.paid_state != "manual_review"
      return if dependency_labels.empty?

      issue.update!(manual_review_reason: dependency_reason)
    end

    def dependency_labels
      @dependency_labels ||= Issues::CloseoutStatus.prerequisite_labels(issue)
    end

    def dependency_reason
      "Paid's agent run completed and opened a pull request, but this issue remains open and is " \
        "#{Issue::DEPENDENCY_BLOCKED_REASON_MARKER}: #{dependency_labels.join(', ')}. This issue stays pending until " \
        "the dependency resolves or a human intervenes."
    end

    def record_audit_event
      Audit::RecordEvent.call(
        action: "issue.reopen_review_decided",
        actor: actor,
        subject: issue,
        metadata: {
          "decision" => decision,
          "reason" => reason,
          "revision" => revision
        }
      )
    end

    def failure(code, message) = Result.new(code:, message:)
  end
end
