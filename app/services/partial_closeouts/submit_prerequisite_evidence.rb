# frozen_string_literal: true

module PartialCloseouts
  # Records an operator supplied item of evidence against one, immutable
  # partial-closeout prerequisite. Submission is deliberately not resolution:
  # a URL, run, report, or dismissal is only a candidate for assessment.
  # @spec PARTIAL-CLOSEOUT-030
  class SubmitPrerequisiteEvidence
    TYPES = %w[url artifact evaluation report run].freeze
    Result = Data.define(:status, :submission, :error) do
      def success? = error.nil?
    end

    def self.call(...) = new(...).call

    def initialize(notification:, actor:, prerequisite_id:, evidence_type:, reference:, explanation:)
      @notification = notification
      @actor = actor
      @prerequisite_id = prerequisite_id.to_s
      @evidence_type = evidence_type.to_s
      @reference = reference.to_s.strip
      @explanation = explanation.to_s.strip
    end

    def call
      notification.with_lock do
        return failure("the prerequisite is no longer available") unless prerequisite
        return failure("the prerequisite evidence changed; submit against the current revision") unless current_revision?
        return failure("evidence type is unsupported") unless TYPES.include?(evidence_type)
        return failure("evidence reference is required") if reference.blank?
        return failure("an explanation of how this meets the prerequisite is required") if explanation.blank?
        return failure("a URL evidence reference must be HTTP(S)") if evidence_type == "url" && !reference.match?(%r{\Ahttps?://}i)

        submission = {
          "id" => SecureRandom.uuid,
          "prerequisite_id" => prerequisite_id,
          "type" => evidence_type,
          "reference" => reference,
          "explanation" => explanation,
          "actor_id" => actor.id,
          "submitted_at" => Time.current.iso8601,
          "source_revision" => source_revision,
          "intent_revision" => intent_revision,
          "outcome" => "pending_validation",
          "reasoning" => "Evidence was submitted and awaits bounded assessment; submission does not satisfy acceptance."
        }
        notification.update!(metadata: metadata.merge("evidence_submissions" => submissions + [ submission ]))
        Result.new(status: "pending_validation", submission: submission, error: nil)
      end
    end

    private

    attr_reader :notification, :actor, :prerequisite_id, :evidence_type, :reference, :explanation

    def metadata = notification.metadata.to_h.deep_stringify_keys
    def prerequisites = Array(metadata["prerequisites"])
    def prerequisite = prerequisites.find { |item| item["id"] == prerequisite_id }
    def submissions = Array(metadata["evidence_submissions"])
    def source_revision = metadata["source_revision"]
    def intent_revision = metadata["intent_revision"]

    def current_revision?
      issue = notification.subject
      issue.is_a?(Issue) && source_revision == Issues::CloseoutEvidence.call(issue).digest &&
        intent_revision == Assessment.intent_revision_for(issue)
    end

    def failure(error) = Result.new(status: "rejected", submission: nil, error: error)
  end
end
