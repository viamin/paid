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

      evidence = CloseoutEvidence.call(issue)
      return failure(:not_stalled, "This issue has no terminal closeout evidence.") unless evidence.present? && issue.github_state == "open"

      issue.resolve_closeout!(actor:, evidence_digest: evidence.digest)
      issue.project.account.account_activity_events.create!(action: "issue.closeout_resolved", actor:, subject: issue,
        metadata: { "reason" => reason, "evidence_digest" => evidence.digest })
      Result.new(issue:)
    end

    private

    attr_reader :actor, :issue, :reason
    def failure(code, message) = Result.new(code:, message:)
  end
end
