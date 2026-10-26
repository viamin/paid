# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends an auditable post-unblinding correction without rewriting the
    # frozen reference label or its original report comparison.
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
        return failure("reference judgments must be frozen before a correction") unless evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id

        label = evaluation.labels.find_by(case_id: case_id)
        return failure("case #{case_id.inspect} has no frozen reference judgment") unless label&.labeled?
        return failure("the cited evidence must be one of #{evidence_references.join(', ')}") unless evidence_references.include?(citation)

        revision = evaluation.label_revisions.create!(facet_confidence_evaluation_label: label, case_id: case_id,
          verdict: judgment.fetch(:verdict).presence, intent_band: judgment.fetch(:intent_band).presence,
          technical_band: judgment.fetch(:technical_band).presence, readiness: judgment.fetch(:readiness).presence,
          cited_evidence_reference: citation, reason: judgment.fetch(:reason).to_s.strip,
          revised_by: actor, revised_at: Time.current)
        Result.new(success: true, error: nil, revision: revision)
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment
      def citation = judgment.fetch(:cited_evidence_reference).to_s.strip
      def evidence_references = evaluation.corpus.find_case(case_id).fetch("evidence").map { |item| item.fetch("reference") }
      def failure(error) = Result.new(success: false, error: error, revision: nil)
    end
  end
end
