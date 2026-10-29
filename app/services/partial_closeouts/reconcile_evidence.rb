# frozen_string_literal: true

module PartialCloseouts
  # Applies a trusted validation result to one submitted prerequisite
  # occurrence. Submitting a link is never itself an acceptance decision.
  # @spec PARTIAL-CLOSEOUT-033
  class ReconcileEvidence
    OUTCOMES = %w[sufficient insufficient unavailable].freeze
    Result = Data.define(:outcome, :reason, :notification) do
      def sufficient? = outcome == "sufficient"
    end

    def self.call(...) = new(...).call

    def initialize(notification:, prerequisite_identity:, evidence_url:, explanation:, outcome:, reason: nil,
                   validator: nil)
      @notification = notification
      @prerequisite_identity = prerequisite_identity.to_s
      @evidence_url = evidence_url.to_s.strip
      @explanation = explanation.to_s.strip
      @requested_outcome = outcome.to_s
      @reason = reason.to_s.strip
      @validator = validator
    end

    def call
      notification.with_lock do
        validate!
        entry = submission.merge(
          "outcome" => reconciled_outcome,
          "reason" => reconciliation_reason,
          "validated_at" => Time.current.iso8601
        )
        entry["validator_id"] = validator.id if validator
        update_submission!(entry)
        resolve_if_complete!
        Result.new(outcome: entry.fetch("outcome"), reason: entry.fetch("reason"), notification:)
      end
    end

    private

    attr_reader :notification, :prerequisite_identity, :evidence_url, :explanation,
      :requested_outcome, :reason, :validator

    def validate!
      raise ArgumentError, "notification is not a partial-closeout prerequisite" unless notification.source == PREREQUISITE_NOTIFICATION_SOURCE
      raise ArgumentError, "notification is no longer active" unless notification.active?
      raise ArgumentError, "prerequisite identity is required" if prerequisite_identity.blank?
      raise ArgumentError, "validation outcome is invalid" unless OUTCOMES.include?(requested_outcome)
      raise ArgumentError, "submitted evidence was not found" unless submission
    end

    def submission
      @submission ||= Array(notification.metadata["evidence_submissions"]).reverse.find do |candidate|
        candidate["prerequisite_identity"] == prerequisite_identity &&
          candidate["evidence_url"] == evidence_url && candidate["explanation"] == explanation
      end
    end

    def occurrence
      @occurrence ||= PrerequisiteOccurrences.for(notification).find do |candidate|
        candidate["identity"] == prerequisite_identity
      end
    end

    def source_revision_current?
      expected = occurrence&.fetch("source_revision", nil)
      expected.blank? || expected == PartialCloseouts::Assessment.source_revision_for(notification.subject)
    end

    def reconciled_outcome
      return "stale" unless source_revision_current?

      requested_outcome
    end

    def reconciliation_reason
      return "The closeout evidence changed; submit evidence for the current prerequisite revision." if reconciled_outcome == "stale"
      return reason if reason.present?

      requested_outcome == "sufficient" ? "Validated evidence satisfies this prerequisite." : "Validated evidence does not satisfy this prerequisite."
    end

    def update_submission!(entry)
      submissions = Array(notification.metadata["evidence_submissions"])
      index = submissions.index(submission)
      submissions[index] = entry
      notification.update!(metadata: notification.metadata.merge("evidence_submissions" => submissions))
    end

    def resolve_if_complete!
      return unless all_occurrences_sufficient?

      notification.update!(resolved_at: Time.current)
    end

    def all_occurrences_sufficient?
      occurrences = PrerequisiteOccurrences.for(notification)
      occurrences.present? && occurrences.all? do |candidate|
        Array(notification.metadata["evidence_submissions"]).any? do |candidate_submission|
          candidate_submission["prerequisite_identity"] == candidate["identity"] &&
            candidate_submission["outcome"] == "sufficient" &&
            current_submission?(candidate, candidate_submission)
        end
      end
    end

    def current_submission?(candidate, candidate_submission)
      candidate["source_revision"].blank? || candidate["source_revision"] == candidate_submission["source_revision"]
    end
  end
end
