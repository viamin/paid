# frozen_string_literal: true

module PartialCloseouts
  # Persists an operator-supplied, revision-bound candidate for one human
  # prerequisite. Submission is deliberately not acceptance: the next bounded
  # acceptance audit is the semantic authority for sufficiency.
  # @spec PARTIAL-CLOSEOUT-030
  class SubmitPrerequisiteEvidence
    Result = Data.define(:success, :message, :notification) do
      def success? = success
    end

    TYPES = %w[url artifact evaluation report run].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, criterion_index:, evidence_type:, reference:, revision:, explanation:)
      @issue, @actor, @criterion_index = issue, actor, criterion_index.to_i
      @evidence_type, @reference, @revision, @explanation = evidence_type, reference, revision, explanation
    end

    def call
      notification = active_notification
      return failure("No active human prerequisite request exists for this issue.") unless notification
      return failure("Choose a supported evidence type.") unless TYPES.include?(evidence_type)
      return failure("Evidence reference, revision, and explanation are required.") if [ reference, revision, explanation ].any? { |value| value.to_s.strip.blank? }
      return failure("A link reference must be an HTTP(S) URL.") if evidence_type == "url" && !reference.match?(%r{\Ahttps?://})
      return failure("The selected prerequisite is no longer current.") unless prerequisite(notification)

      notification.with_lock do
        metadata = notification.metadata.deep_stringify_keys
        submissions = Array(metadata["evidence_submissions"])
        submissions << submission(metadata)
        notification.update!(metadata: metadata.merge("evidence_submissions" => submissions))
      end
      Result.new(success: true, message: "Evidence submitted for validation. It does not yet satisfy the prerequisite.", notification: notification)
    end

    private

    attr_reader :issue, :actor, :criterion_index, :evidence_type, :reference, :revision, :explanation

    def active_notification
      issue.project.account.notifications.active.find_by(source: PREREQUISITE_NOTIFICATION_SOURCE, subject: issue)
    end

    def prerequisite(notification)
      Array(notification.metadata.deep_stringify_keys["prerequisites"])[criterion_index]
    end

    def submission(metadata)
      {
        "id" => SecureRandom.uuid, "criterion_index" => criterion_index, "type" => evidence_type,
        "reference" => reference.strip, "revision" => revision.strip, "explanation" => explanation.strip,
        "actor_id" => actor.id, "submitted_at" => Time.current.iso8601, "outcome" => "pending_validation",
        "source_revision" => Issues::CloseoutEvidence.call(issue).digest,
        "intent_revision" => Assessment.intent_revision_for(issue),
        "prerequisite" => prerequisite_from(metadata)
      }
    end

    def prerequisite_from(metadata) = Array(metadata["prerequisites"])[criterion_index]
    def failure(message) = Result.new(success: false, message: message, notification: nil)
  end
end
