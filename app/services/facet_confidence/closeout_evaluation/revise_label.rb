# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends a post-unblinding correction without changing the blinded label.
    # @spec FACET-CONFIDENCE-021
    class ReviseLabel
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
        @evaluation.with_lock { append_revision }
      end

      private

      def append_revision
        return failure("reference judgments must be frozen before they can be revised") unless @evaluation.frozen?
        return failure("only the operator who started the evaluation may revise its reference judgments") unless @actor&.id == @evaluation.created_by_id

        corpus_case = @evaluation.corpus.find_case(@case_id)
        return failure("case #{@case_id.inspect} is not part of the frozen corpus") unless corpus_case

        label = @evaluation.labels.find_by(case_id: @case_id)
        return failure("only a frozen labeled judgment can be revised") unless label&.labeled?
        return failure("the cited evidence must be one of #{evidence_references(corpus_case).join(', ')}") unless evidence_references(corpus_case).include?(cited_reference)
        return failure("a revision reason is required") if @judgment.fetch(:reason).to_s.strip.empty?

        revision = revision_for(label)
        validate_revision!(label, revision)
        report = @evaluation.report.deep_dup
        revisions = report.fetch("post_unblinding_revisions", {}).deep_dup
        revisions[@case_id] = Array(revisions[@case_id]) + [ revision ]
        @evaluation.update!(report: report.merge("post_unblinding_revisions" => revisions))
        CompileReport.call(evaluation: @evaluation)
        Result.new(success: true, error: nil, revision: revision)
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      def revision_for(label)
        @judgment.stringify_keys.slice("verdict", "intent_band", "technical_band", "readiness", "reason")
          .merge("cited_evidence_reference" => cited_reference, "recorded_by_id" => @actor.id,
            "recorded_at" => Time.current.iso8601, "original_recorded_at" => label.recorded_at.iso8601)
      end

      def validate_revision!(label, revision)
        attributes = label.attributes.slice("case_id", "state").merge(revision.slice("verdict", "intent_band", "technical_band", "readiness", "cited_evidence_reference", "reason"))
          .merge("facet_confidence_evaluation_id" => @evaluation.id, "recorded_by_id" => @actor.id, "recorded_at" => Time.current)
        FacetConfidenceEvaluationLabel.new(attributes).validate!
      end

      def evidence_references(corpus_case)
        corpus_case.fetch("evidence").map { |evidence| evidence.fetch("reference") }
      end

      def cited_reference = @judgment.fetch(:cited_evidence_reference).to_s.strip
      def failure(message) = Result.new(success: false, error: message, revision: nil)
    end
  end
end
