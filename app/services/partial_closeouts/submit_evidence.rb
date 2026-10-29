# frozen_string_literal: true

require "uri"

module PartialCloseouts
  # Records an operator's evidence against one durable prerequisite occurrence.
  # A submission is deliberately not an attestation: only a future assessor may
  # mark an occurrence sufficient and release its scheduling guard.
  # @spec PARTIAL-CLOSEOUT-033
  class SubmitEvidence
    OUTCOMES = %w[pending_validation sufficient insufficient stale unavailable].freeze
    Result = Data.define(:outcome, :reason, :notification, :submission_id, :new_submission) do
      def sufficient? = outcome == "sufficient"
      def new_submission? = new_submission
    end

    def self.call(...) = new(...).call

    def initialize(notification:, actor:, prerequisite_identity:, evidence_url:, explanation:)
      @notification = notification
      @actor = actor
      @prerequisite_identity = prerequisite_identity.to_s
      @evidence_url = evidence_url.to_s.strip
      @explanation = explanation.to_s.strip
    end

    def call
      result = notification.with_lock do
        validate!
        PrerequisiteOccurrences.upgrade!(notification)
        record_submission!
      end
      enqueue_validation(result) if result.new_submission? && result.outcome == "pending_validation"
      result
    end

    private

    attr_reader :actor, :evidence_url, :explanation, :notification, :prerequisite_identity

    def validate!
      raise ArgumentError, "notification is not a partial-closeout prerequisite" unless notification.source == PREREQUISITE_NOTIFICATION_SOURCE
      raise ArgumentError, "notification is no longer active" unless notification.active?
      raise ArgumentError, "prerequisite identity is required" if prerequisite_identity.blank?
      raise ArgumentError, "evidence must be an HTTP(S) URL" unless valid_evidence_url?
      raise ArgumentError, "explanation is required" if explanation.blank?
      raise ArgumentError, "prerequisite occurrence is no longer current" unless occurrence
    end

    def record_submission!
      submissions = Array(notification.metadata["evidence_submissions"])
      existing_submission = submissions.find { |submission| duplicate_submission?(submission) }
      return result_for(existing_submission, new_submission: false) if existing_submission&.key?("submission_id")
      return assign_submission_id!(submissions, existing_submission) if existing_submission

      entry = { "submission_id" => SecureRandom.uuid, "prerequisite_identity" => prerequisite_identity, "evidence_url" => evidence_url,
                "explanation" => explanation, "actor_id" => actor.id, "submitted_at" => Time.current.iso8601,
                "source_revision" => occurrence.fetch("source_revision", nil), "outcome" => outcome, "reason" => reason }
      notification.update!(metadata: notification.metadata.merge("evidence_submissions" => submissions + [ entry ]))
      result_for(entry, new_submission: true)
    end

    def assign_submission_id!(submissions, submission)
      identified_submission = submission.merge("submission_id" => SecureRandom.uuid)
      identified_submissions = submissions.dup
      identified_submissions[identified_submissions.index(submission)] = identified_submission
      notification.update!(metadata: notification.metadata.merge(
        "evidence_submissions" => identified_submissions
      ))
      result_for(identified_submission, new_submission: identified_submission["outcome"] == "pending_validation")
    end

    def result_for(submission, new_submission:)
      Result.new(outcome: submission.fetch("outcome"), reason: submission.fetch("reason"), notification:,
        submission_id: submission.fetch("submission_id"), new_submission:)
    end

    def duplicate_submission?(submission)
      submission.slice("prerequisite_identity", "evidence_url", "explanation") ==
        entry_identity
    end

    def entry_identity
      { "prerequisite_identity" => prerequisite_identity, "evidence_url" => evidence_url, "explanation" => explanation }
    end

    # A link proves neither its contents nor applicability. Keep it pending for
    # bounded agent_harness assessment rather than granting a completion path
    # through an unchecked comment, upload, green run, or dismissed alert.
    def outcome = source_revision_current? ? "pending_validation" : "stale"

    def reason
      return "The closeout evidence changed; submit evidence for the current prerequisite revision." unless source_revision_current?

      "Evidence was recorded for validation. A link alone does not satisfy acceptance."
    end

    def source_revision_current?
      expected = occurrence.fetch("source_revision", nil)
      expected.blank? || expected == current_source_revision
    end

    def current_source_revision = @current_source_revision ||= PartialCloseouts::Assessment.source_revision_for(notification.subject)

    def valid_evidence_url?
      uri = URI.parse(evidence_url)
      uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end

    def enqueue_validation(result)
      ValidateSubmittedEvidenceJob.perform_later(notification.id, prerequisite_identity, result.submission_id)
    end

    def occurrence
      PrerequisiteOccurrences.for(notification).find { |item| item["identity"] == prerequisite_identity }
    end
  end
end
