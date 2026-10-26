# frozen_string_literal: true

require "digest"

module PartialCloseouts
  # Records evidence against one named prerequisite. Structural checks happen
  # here; semantic sufficiency remains a bounded assessment, never a side
  # effect of a URL, green run, report, or notification dismissal.
  # @spec PARTIAL-CLOSEOUT-030
  class SubmitEvidence
    Result = Data.define(:success, :submission, :error) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, criterion:, evidence_kind:, explanation:, source_url: nil, source_record_id: nil)
      @issue = issue
      @actor = actor
      @criterion = criterion.to_s.strip
      @evidence_kind = evidence_kind.to_s
      @explanation = explanation.to_s.strip
      @source_url = source_url.to_s.strip.presence
      @source_record_id = source_record_id.presence
    end

    def call
      return failure("Select the exact prerequisite and explain why this evidence applies.") if criterion.blank? || explanation.blank?
      return failure("That evidence type is not supported.") unless PartialCloseoutEvidenceSubmission::EVIDENCE_KINDS.include?(evidence_kind)
      return failure("A durable artifact or link requires an HTTP(S) URL.") if link? && source_url.blank?

      notification = prerequisite_notification
      return failure("This prerequisite is no longer active; refresh the Inbox item.") unless notification
      return failure("That prerequisite is not part of the current assessment.") unless prerequisite?(notification)

      submit!(notification)
    rescue ActiveRecord::RecordNotUnique
      failure("This evidence generation was already submitted for that prerequisite.")
    end

    private

    attr_reader :issue, :actor, :criterion, :evidence_kind, :explanation, :source_url, :source_record_id

    def submit!(notification)
      issue.with_lock do
        return failure("The prerequisite changed while this evidence was being submitted.") unless current?(notification)

        submission = PartialCloseoutEvidenceSubmission.create!(
          issue:, notification:, actor:, criterion:, evidence_kind:, source_url:, source_record_id:,
          prerequisite_identity: prerequisite_identity(notification),
          source_revision: assessment.source_revision, intent_revision: assessment.intent_revision,
          outcome: disposition, reason: disposition_reason, explanation:,
          provenance: { "actor_id" => actor.id, "notification_id" => notification.id, "submitted_at" => Time.current.iso8601 },
          validated_at: validation_time
        )
        Result.new(success: true, submission:, error: nil)
      end
    end

    def prerequisite_notification
      issue.project.account.notifications.active.find_by(source: PREREQUISITE_NOTIFICATION_SOURCE, subject: issue)
    end

    def assessment = @assessment ||= Assessment.call(issue)

    def prerequisite?(notification)
      notification.description.to_s.lines.any? { |line| line.start_with?("#{criterion}:") }
    end

    # The notification row and assessment revision scope this identity to one
    # occurrence. Identical wording from a later assessment is a new
    # prerequisite and cannot inherit an earlier submission.
    def prerequisite_identity(notification)
      Digest::SHA256.hexdigest([ notification.id, criterion, assessment.source_revision, assessment.intent_revision ].join("\0"))
    end

    def current?(notification)
      notification.active? && !assessment.stale?
    end

    def link? = evidence_kind.in?(%w[durable_artifact link])

    # A shadow report is deliberately weaker than a human reference judgment
    # and preserves its explicit missing production measures. Other external
    # evidence is pending a bounded semantic assessment rather than accepted
    # by structural shape alone.
    def disposition = evidence_kind == "shadow_evaluation_report" ? "insufficient" : "pending_validation"

    def disposition_reason
      return "The evaluation report preserves missing production measures and weaker solo-maintainer assurance; it is not acceptance proof." if evidence_kind == "shadow_evaluation_report"

      "Evidence was recorded with its current revisions and provenance. A bounded acceptance assessment is still required."
    end

    def validation_time
      Time.current if disposition == "insufficient"
    end

    def failure(error) = Result.new(success: false, submission: nil, error: error)
  end
end
