# frozen_string_literal: true

module PartialCloseouts
  # Applies the existing bounded semantic assessment to submitted evidence.
  # Only the affected prerequisite occurrences are resolved; dismissal remains
  # a personal Inbox action and has no evidentiary effect.
  # @spec PARTIAL-CLOSEOUT-031
  class ReconcilePrerequisiteEvidence
    def self.call(...) = new(...).call

    def initialize(issue:, assessment:)
      @issue, @assessment = issue, assessment.deep_stringify_keys
    end

    def call
      notification = issue.project.account.notifications.active.find_by(source: PREREQUISITE_NOTIFICATION_SOURCE, subject: issue)
      return unless notification

      notification.with_lock do
        metadata = notification.metadata.deep_stringify_keys
        submissions = Array(metadata["evidence_submissions"])
        return if submissions.empty?

        current = current_revisions?
        submissions.each { |submission| reconcile_submission!(submission, current) }
        metadata["evidence_submissions"] = submissions
        notification.update!(metadata: metadata)
        notification.update!(resolved_at: Time.current) if complete?(metadata)
      end
    end

    private

    attr_reader :issue, :assessment

    def current_revisions?
      assessment["source_revision"] == Issues::CloseoutEvidence.call(issue).digest &&
        assessment["intent_revision"] == Assessment.intent_revision_for(issue)
    end

    def reconcile_submission!(submission, current)
      return submission["outcome"] = "stale" unless current && submission["source_revision"] == assessment["source_revision"] && submission["intent_revision"] == assessment["intent_revision"]
      return unless submission["outcome"] == "pending_validation"

      criterion = Array(assessment["criteria"]).find { |item| item["criterion"] == submission.dig("prerequisite", "criterion") }
      submission["outcome"] = criterion&.fetch("state", nil) == "satisfied" ? "sufficient" : "insufficient"
      submission["reasoning"] = criterion ? "Acceptance audit classified this criterion as #{criterion["state"]}." : "The audit did not establish this prerequisite criterion."
      submission["validated_at"] = Time.current.iso8601
    end

    def complete?(metadata)
      prerequisites = Array(metadata["prerequisites"])
      return false if prerequisites.empty?

      prerequisites.each_index.all? do |index|
        Array(metadata["evidence_submissions"]).any? { |submission| submission["criterion_index"] == index && submission["outcome"] == "sufficient" }
      end
    end
  end
end
