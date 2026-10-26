# frozen_string_literal: true

module PartialCloseouts
  # Records evidence against one exact human prerequisite occurrence. Submission
  # is deliberately not resolution: a report, URL, or green run first remains
  # pending until the existing bounded acceptance audit assesses it.
  # @spec PARTIAL-CLOSEOUT-028
  class SubmitEvidence
    Result = Data.define(:success, :error, :submission) do
      def success? = success
    end

    KINDS = %w[artifact link evaluation report run].freeze

    def self.call(...) = new(...).call

    def initialize(notification:, actor:, kind:, reference:, explanation:, revisions: {})
      @notification, @actor, @kind, @reference, @explanation, @revisions = notification, actor, kind, reference, explanation, revisions
    end

    def call
      return failure("This prerequisite is no longer active.") unless notification.active? && notification.source == PREREQUISITE_NOTIFICATION_SOURCE
      return failure("Choose a supported evidence type.") unless KINDS.include?(kind)
      return failure("Provide an evidence reference and explanation.") if reference.blank? || explanation.blank?

      submission = {
        "id" => SecureRandom.uuid, "kind" => kind, "reference" => reference,
        "explanation" => explanation, "outcome" => "pending_validation",
        "actor_id" => actor.id, "submitted_at" => Time.current.iso8601,
        "revisions" => revisions.compact, "prerequisite" => notification.description
      }
      notification.with_lock do
        metadata = notification.metadata.to_h.deep_stringify_keys
        notification.update!(metadata: metadata.merge("evidence_submissions" => Array(metadata["evidence_submissions"]) + [ submission ]))
      end
      Result.new(success: true, error: nil, submission: submission)
    end

    private

    attr_reader :notification, :actor, :kind, :reference, :explanation, :revisions

    def failure(error) = Result.new(success: false, error: error, submission: nil)
  end
end
