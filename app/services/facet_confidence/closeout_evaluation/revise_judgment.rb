# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends an attributed correction only after unblinding. It never mutates
    # the frozen label used by the original comparison, then recompiles the
    # retained report so its revision history is visible from the Inbox.
    # @spec FACET-CONFIDENCE-021
    class ReviseJudgment
      ReportCompilationFailed = Class.new(StandardError)

      Result = Data.define(:success, :error, :revision) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, judgment:)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @judgment = judgment
      end

      def call
        @evaluation.with_lock { revise }
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      rescue ReportCompilationFailed => error
        failure(error.message)
      end

      private

      def revise
        return failure("corrections are recorded only after the reference set is frozen") unless @evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless @actor&.id == @evaluation.created_by_id

        label = @evaluation.labels.find_by(case_id: @case_id, state: "labeled")
        return failure("case #{@case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("the cited evidence must be one of #{case_evidence_references.join(', ')}") unless case_evidence_references.include?(cited_evidence_reference)

        revision = label.judgment_revisions.create!(**judgment_attributes)
        report = CompileReport.call(evaluation: @evaluation)
        raise ReportCompilationFailed, report.error unless report.success?

        log_revision(revision)
        Result.new(success: true, error: nil, revision: revision)
      end

      def judgment_attributes
        {
          verdict: @judgment.fetch(:verdict).presence,
          intent_band: @judgment.fetch(:intent_band).presence,
          technical_band: @judgment.fetch(:technical_band).presence,
          readiness: @judgment.fetch(:readiness).presence,
          cited_evidence_reference: cited_evidence_reference,
          reason: @judgment.fetch(:reason).to_s.strip,
          revised_by: @actor,
          revised_at: Time.current
        }
      end

      def cited_evidence_reference = @judgment.fetch(:cited_evidence_reference).to_s.strip

      def case_evidence_references
        @evaluation.corpus.find_case(@case_id).to_h.fetch("evidence", []).map { |item| item.fetch("reference") }
      end

      def log_revision(revision)
        Rails.logger.info(message: "facet_confidence.reference_judgment_revised",
          project_id: @evaluation.project_id, facet_confidence_evaluation_id: @evaluation.id,
          case_id: @case_id, revision_id: revision.id, actor_user_id: @actor.id)
      end

      def failure(message) = Result.new(success: false, error: message, revision: nil)
    end
  end
end
