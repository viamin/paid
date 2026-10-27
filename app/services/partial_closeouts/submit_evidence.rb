# frozen_string_literal: true

require "uri"

module PartialCloseouts
  # Records an operator's evidence against one durable prerequisite occurrence.
  # A submission is deliberately not an attestation: only a future assessor may
  # mark an occurrence sufficient and release its scheduling guard.
  # @spec PARTIAL-CLOSEOUT-033
  class SubmitEvidence
    OUTCOMES = %w[pending_validation sufficient insufficient stale unavailable].freeze
    Result = Data.define(:outcome, :reason, :notification) do
      def sufficient? = outcome == "sufficient"
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
      notification.with_lock do
        validate!
        record_submission!
      end
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
      entry = { "prerequisite_identity" => prerequisite_identity, "evidence_url" => evidence_url,
                "explanation" => explanation, "actor_id" => actor.id, "submitted_at" => Time.current.iso8601,
                "source_revision" => occurrence.fetch("source_revision", nil), "outcome" => outcome, "reason" => reason }
      notification.update!(metadata: notification.metadata.merge("evidence_submissions" => replace_duplicate(submissions, entry)))
      Result.new(outcome:, reason:, notification:)
    end

    def replace_duplicate(submissions, entry)
      index = submissions.index { |submission| duplicate_submission?(submission) }
      return submissions + [ entry ] unless index

      submissions.dup.tap { |updated| updated[index] = entry }
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

    def occurrence
      @occurrence ||= Array(notification.metadata["prerequisites"]).find { |item| item["identity"] == prerequisite_identity }
    end
  end
end
