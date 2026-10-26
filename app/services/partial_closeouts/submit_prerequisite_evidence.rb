# frozen_string_literal: true

module PartialCloseouts
  # Records evidence against one exact human prerequisite occurrence. A link,
  # green run, report, or notification dismissal is not itself acceptance: the
  # disposition remains explicit and only a sufficient, current assessment may
  # resolve the scheduling notification.
  # @spec PARTIAL-CLOSEOUT-030
  class SubmitPrerequisiteEvidence
    EVIDENCE_TYPES = %w[evaluation_report agent_run artifact link].freeze
    STATUSES = %w[pending sufficient insufficient stale unavailable].freeze
    Result = Data.define(:success, :error, :submission) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(notification:, actor:, prerequisite_id:, evidence_type:, reference:, explanation:, assessor: EvidenceAssessment)
      @notification, @actor, @prerequisite_id = notification, actor, prerequisite_id
      @evidence_type, @reference, @explanation, @assessor = evidence_type, reference, explanation, assessor
    end

    def call
      notification.with_lock do
        return failure("the prerequisite notification is no longer active") unless notification.active?
        return failure("evidence type is unsupported") unless EVIDENCE_TYPES.include?(evidence_type)
        return failure("a durable evidence reference and explanation are required") if reference.blank? || explanation.blank?

        prerequisite = prerequisites.find { |item| item["id"] == prerequisite_id }
        return failure("the named prerequisite is not on this notification") unless prerequisite

        submission = build_submission(prerequisite)
        assessment = assessor.call(submission:, notification:, prerequisite:)
        return failure(assessment.fetch("reason")) unless STATUSES.include?(assessment["status"])

        submission.merge!(assessment.slice("status", "reason", "assessed_at"))
        persist!(submission)
        resolve_notification_if_complete! if submission["status"] == "sufficient"
        Result.new(success: true, error: nil, submission: submission)
      end
    end

    private

    attr_reader :notification, :actor, :prerequisite_id, :evidence_type, :reference, :explanation, :assessor

    def prerequisites = Array(notification.metadata["prerequisites"])

    def build_submission(prerequisite)
      {
        "id" => SecureRandom.uuid, "prerequisite_id" => prerequisite_id, "evidence_type" => evidence_type,
        "reference" => reference, "explanation" => explanation, "actor_id" => actor.id,
        "submitted_at" => Time.current.iso8601, "source_revision" => prerequisite["source_revision"],
        "intent_revision" => prerequisite["intent_revision"], "provenance" => { "notification_id" => notification.id }
      }
    end

    def persist!(submission)
      metadata = notification.metadata.deep_dup
      metadata["evidence_submissions"] = Array(metadata["evidence_submissions"]) + [ submission ]
      notification.update!(metadata: metadata)
    end

    # One action-required notification can project several prerequisites. Do
    # not release its guard when only one occurrence is sufficient; that would
    # convert partial evidence into whole-closeout scheduling authority.
    def resolve_notification_if_complete!
      latest = Array(notification.metadata["evidence_submissions"]).reverse_each.with_object({}) do |item, by_prerequisite|
        by_prerequisite[item["prerequisite_id"]] ||= item
      end
      return unless prerequisites.all? { |item| latest.dig(item["id"], "status") == "sufficient" }

      Notifications::Resolve.call(account: notification.account, source: notification.source, subject: notification.subject)
    end

    def failure(error) = Result.new(success: false, error: error, submission: nil)
  end
end
