# frozen_string_literal: true

module Inbox
  # Typed presentation for the facet-confidence evaluation embedded in a
  # partial-closeout prerequisite notification. The notification source is the
  # contract; no workflow is inferred from untrusted notification prose.
  # @spec FACET-CONFIDENCE-022
  class FacetConfidenceEscalation
    def self.for(...) = new(...).call

    def initialize(notification:, project:, issue:)
      @notification = notification
      @project = project
      @issue = issue
    end

    def call
      return unless applicable?
      return unless packet.ready?

      self
    end

    def action
      return :start unless evaluation
      return :review if evaluation.frozen?
      return :freeze if progress[:remaining].zero?

      :continue_judging
    end

    def title
      {
        start: "Evaluation needed",
        continue_judging: "Continue independent review",
        freeze: "Freeze completed judgments",
        review: "Evaluation complete"
      }.fetch(action)
    end

    def explanation
      return "The independent review is complete. You can review the recorded results." if action == :review

      "This closeout is blocked until a human independently reviews every frozen test case, records a judgment for each one, and freezes the completed set. #{next_step}"
    end

    def progress
      return { total: 0, recorded: 0, remaining: 0, skipped: 0 } unless evaluation

      snapshot = evaluation.progress
      {
        total: snapshot[:total],
        recorded: snapshot[:labeled],
        remaining: snapshot[:total] - snapshot[:labeled],
        skipped: snapshot[:skipped]
      }
    end

    private

    attr_reader :notification, :project, :issue

    def applicable?
      notification.source == PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE && issue.present?
    end

    def packet
      status = FacetConfidence::CloseoutEvaluation::EscalationStatus.call(
        status: Issues::CloseoutStatus.call(issue), notification_id: notification.id
      )
      @packet ||= FacetConfidence::CloseoutEvaluationPacket.call(
        issue: issue, status: status
      )
    end

    def evaluation
      return @evaluation if defined?(@evaluation)

      @evaluation = issue.facet_confidence_evaluations.where(corpus_digest: packet.corpus_digest).latest_first.first
    end

    public :evaluation

    def next_step
      case action
      when :start then "Start the evaluation to begin reviewing the cases."
      when :continue_judging then "#{progress[:remaining]} judgment(s) still need attention."
      when :freeze then "Every case has a recorded judgment and the set is ready to freeze."
      end
    end
  end
end
