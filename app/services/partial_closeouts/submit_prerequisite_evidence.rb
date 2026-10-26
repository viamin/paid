# frozen_string_literal: true

module PartialCloseouts
  # Records an exact prerequisite submission. Structural applicability is
  # deterministic; semantic sufficiency remains a bounded assessment and is
  # never inferred from a URL, green run, report, or dismissal.
  # @spec PARTIAL-CLOSEOUT-030
  class SubmitPrerequisiteEvidence
    Result = Data.define(:success, :evidence, :error) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, criterion:, evidence_type:, evidence_reference:, explanation:, idempotency_key:, shadow_evaluation: nil)
      @issue, @actor, @criterion, @evidence_type, @evidence_reference, @explanation, @idempotency_key, @shadow_evaluation =
        issue, actor, criterion.to_s.strip, evidence_type.to_s, evidence_reference.to_s.strip, explanation.to_s.strip, idempotency_key.to_s.strip, shadow_evaluation
    end

    def call
      return failure("Select an exact current human or external prerequisite.") unless applicable?
      return failure("Explain why this evidence satisfies the prerequisite.") if explanation.blank?
      return failure("Provide a durable evidence reference and replay key.") if evidence_reference.blank? || idempotency_key.blank?

      evidence = existing
      return failure("That replay key belongs to a different prerequisite.") if evidence && (evidence.issue_id != issue.id || evidence.criterion != criterion)

      evidence ||= create_evidence
      Result.new(success: true, evidence:, error: nil)
    rescue ActiveRecord::RecordNotUnique
      Result.new(success: true, evidence: existing, error: nil)
    end

    private

    attr_reader :issue, :actor, :criterion, :evidence_type, :evidence_reference, :explanation, :idempotency_key, :shadow_evaluation

    def applicable?
      PartialCloseouts::Assessment.call(issue).criteria.any? do |item|
        item["criterion"] == criterion && item["prerequisite_kind"].in?(%w[human external])
      end
    end

    def existing
      PartialCloseoutPrerequisiteEvidence.find_by(account: issue.project.account, idempotency_key:)
    end

    def create_evidence
      PartialCloseoutPrerequisiteEvidence.create!(
        account: issue.project.account, issue:, actor:, criterion:, evidence_type:, evidence_reference:, explanation:, idempotency_key:,
        shadow_evaluation:, source_revision: Issues::CloseoutEvidence.call(issue).digest,
        intent_revision: PartialCloseouts::Assessment.intent_revision_for(issue)
      )
    end

    def failure(error) = Result.new(success: false, evidence: nil, error:)
  end
end
