# frozen_string_literal: true

module PartialCloseouts
  # Persists an operator's evidence offer against one exact prerequisite. The
  # service performs only structural disposition: semantic sufficiency remains
  # a bounded acceptance-assessment concern, never an implication of a URL or
  # notification action.
  # @spec PARTIAL-CLOSEOUT-030
  class SubmitEvidence
    Result = Data.define(:success, :error, :submission) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, criterion:, evidence_type:, evidence_reference:, source_revision:, explanation:, provenance: {})
      @issue = issue
      @actor = actor
      @criterion = criterion.to_s.strip
      @evidence_type = evidence_type.to_s
      @evidence_reference = evidence_reference.to_s.strip
      @source_revision = source_revision.to_s
      @explanation = explanation.to_s.strip
      @provenance = provenance
    end

    def call
      return failure("criterion, evidence revision, and explanation are required") if required_fields_missing?

      submission = issue.with_lock { persist_submission }
      Result.new(success: true, error: nil, submission:)
    rescue ActiveRecord::RecordInvalid => error
      failure(error.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :issue, :actor, :criterion, :evidence_type, :evidence_reference, :source_revision, :explanation, :provenance

    def required_fields_missing?
      criterion.blank? || evidence_reference.blank? || source_revision.blank? || explanation.blank?
    end

    def persist_submission
      PartialCloseoutEvidenceSubmission.create_or_find_by!(
        issue:, criterion:, evidence_type:, evidence_reference:, source_revision:
      ) do |submission|
        submission.assign_attributes(base_attributes.merge(disposition))
      end
    end

    def base_attributes
      now = Time.current
      {
        account_id: issue.project.account_id, project_id: issue.project_id, issue_id: issue.id, actor_id: actor&.id,
        criterion:, evidence_type:, evidence_reference:, source_revision:, explanation:, provenance: provenance.to_h,
        created_at: now, updated_at: now
      }
    end

    def disposition
      if source_revision != current_revision
        { status: "stale", reasoning: "The closeout evidence changed; submit evidence for the current revision before validation.", assessed_at: Time.current }
      else
        { status: "submitted", reasoning: "Evidence submitted and pending validation by a bounded acceptance assessment.", assessed_at: nil }
      end
    end

    def current_revision
      @current_revision ||= Issues::CloseoutEvidence.call(issue).digest
    end

    def failure(error)
      Result.new(success: false, error:, submission: nil)
    end
  end
end
