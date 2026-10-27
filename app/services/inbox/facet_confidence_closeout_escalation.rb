# frozen_string_literal: true

module Inbox
  # Presentation state for the explicitly typed closeout-evaluation escalation.
  # The notification producer declares this workflow in metadata; do not infer it
  # from its human-readable copy.
  # @spec FACET-CONFIDENCE-022
  class FacetConfidenceCloseoutEscalation
    WORKFLOW = "facet_confidence_closeout_evaluation"
    State = Data.define(:evaluation, :title, :explanation, :action_label, :recorded, :remaining, :total, :skipped) do
      def active? = !evaluation&.frozen?
      def started? = evaluation.present?
      def judge?(actor) = evaluation&.created_by_id == actor.id
    end

    def self.for(notification) = new(notification).state

    def self.closeout_blocker?(issue, blocker)
      notifications = Notification.where(account: issue.project.account, subject: issue,
          source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, resolved_at: nil, dismissed_at: nil)
      blocker.code == :human_prerequisite_notification && notifications.any? &&
        notifications.all? { |notification| notification.metadata["workflow"] == WORKFLOW }
    end

    def initialize(notification)
      @notification = notification
    end

    def state
      return unless notification.metadata["workflow"] == WORKFLOW
      return unless notification.subject.is_a?(Issue)

      evaluation = notification.subject.facet_confidence_evaluations.latest_first.first
      progress = evaluation ? FacetConfidence::CloseoutEvaluation::CaseView.progress(evaluation) : empty_progress
      State.new(evaluation:, recorded: progress[:labeled], total: progress[:total],
        remaining: progress[:total] - progress[:labeled], skipped: progress[:skipped], **copy_for(evaluation, progress))
    end

    private

    attr_reader :notification

    def empty_progress
      { total: FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).case_ids.length, labeled: 0, skipped: 0 }
    end

    def copy_for(evaluation, progress)
      return start_copy unless evaluation
      return frozen_copy if evaluation.frozen?
      return freeze_copy if progress[:labeled] == progress[:total] && progress[:skipped].zero?

      continue_copy
    end

    def start_copy
      { title: "Review test cases before closeout", action_label: "Start evaluation",
        explanation: "This closeout is waiting for an independent human review. Review each frozen test case, record your judgment, and freeze the completed set before the closeout can continue." }
    end

    def continue_copy
      { title: "Continue reviewing test cases", action_label: "Continue judging",
        explanation: "This closeout is still blocked because not every frozen test case has a recorded human judgment. Finish the remaining cases, then freeze the completed set." }
    end

    def freeze_copy
      { title: "Freeze completed judgments", action_label: "Freeze judgments",
        explanation: "Every frozen test case now has a recorded human judgment. Review the set once more, then freeze it to complete this evaluation step." }
    end

    def frozen_copy
      { title: "Evaluation judgments are frozen", action_label: "View evaluation report",
        explanation: "The human review and judgment-freezing step is complete. Open the report to review the recorded evidence for this closeout." }
    end
  end
end
