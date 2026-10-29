# frozen_string_literal: true

module PartialCloseouts
  # Applies a validated prerequisite assessment to one occurrence. A submitted
  # URL is never sufficient by itself; only this reconciliation path may mark
  # it sufficient and release the aggregate scheduling guard.
  # @spec PARTIAL-CLOSEOUT-033
  class ReconcileEvidence
    OUTCOMES = %w[sufficient insufficient stale unavailable].freeze
    Result = Data.define(:outcome, :released, :notification) do
      def released? = released
    end

    def self.call(...) = new(...).call

    def initialize(notification:, prerequisite_identity:, outcome:, reason:, source_revision: nil)
      @notification = notification
      @prerequisite_identity = prerequisite_identity.to_s
      @outcome = outcome.to_s
      @reason = reason.to_s.strip
      @source_revision = source_revision
    end

    def call
      notification.with_lock do
        validate!
        update_submission!(current_submission)
        release_notification! if sufficient? && all_occurrences_sufficient?
        Result.new(outcome:, released: notification.resolved_at.present?, notification:)
      end
    end

    private

    attr_reader :notification, :outcome, :prerequisite_identity, :reason, :source_revision

    def validate!
      raise ArgumentError, "notification is not a partial-closeout prerequisite" unless notification.source == PREREQUISITE_NOTIFICATION_SOURCE
      raise ArgumentError, "notification is no longer active" unless notification.active?
      raise ArgumentError, "prerequisite identity is required" if prerequisite_identity.blank?
      raise ArgumentError, "reconciliation outcome is invalid" unless outcome.in?(OUTCOMES)
      raise ArgumentError, "reconciliation reason is required" if reason.blank?
      raise ArgumentError, "prerequisite occurrence is no longer current" unless occurrence
      raise ArgumentError, "prerequisite source revision is stale" unless current_source_revision?
      raise ArgumentError, "prerequisite evidence has not been submitted" unless current_submission
    end

    def occurrence
      @occurrence ||= PrerequisiteOccurrences.for(notification).find { |item| item["identity"] == prerequisite_identity }
    end

    def current_source_revision?
      expected = occurrence.fetch("source_revision", nil)
      revision_matches = expected.blank? || expected == current_source_revision
      supplied_revision_matches = source_revision.blank? || source_revision == current_source_revision
      revision_matches && supplied_revision_matches
    end

    def current_source_revision = @current_source_revision ||= Assessment.source_revision_for(notification.subject)

    def current_submission
      Array(notification.metadata["evidence_submissions"]).reverse_each.find do |submission|
        submission["prerequisite_identity"] == prerequisite_identity &&
          submission["outcome"] == "pending_validation" &&
          submission["source_revision"].to_s == occurrence.fetch("source_revision", nil).to_s
      end
    end

    def update_submission!(submission)
      submissions = Array(notification.metadata["evidence_submissions"])
      index = submissions.index(submission)
      submissions[index] = submission.merge("outcome" => outcome, "reason" => reason,
        "reconciled_at" => Time.current.iso8601)
      notification.update!(metadata: notification.metadata.merge("evidence_submissions" => submissions))
    end

    def all_occurrences_sufficient?
      PrerequisiteOccurrences.for(notification).all? do |item|
        sufficient_submission_for?(item)
      end
    end

    def sufficient_submission_for?(item)
      Array(notification.metadata["evidence_submissions"]).any? do |submission|
        submission["prerequisite_identity"] == item.fetch("identity") &&
          submission["outcome"] == "sufficient" &&
          (item["source_revision"].blank? || submission["source_revision"] == item["source_revision"])
      end
    end

    def release_notification!
      notification.update!(resolved_at: Time.current,
        metadata: notification.metadata.merge("released_by" => "reconciled_evidence",
          "released_at" => Time.current.iso8601))
    end

    def sufficient? = outcome == "sufficient"
  end
end
