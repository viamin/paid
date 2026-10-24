# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Records (or skips) one blinded reference judgment for the evaluation's
    # sole judge. Only the judge may record, only while the evaluation is in
    # the labeling state, and only for a case inside the frozen corpus with a
    # citation drawn from that case's evidence. Saves are upserts, so
    # save/resume is durable; a skipped case stays skipped (never completed)
    # until explicitly judged.
    # @spec FACET-CONFIDENCE-021
    class RecordLabel
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, judgment: nil)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @judgment = judgment
      end

      def call
        return failure("reference judgments are frozen; the compiled report is the evidence") unless @evaluation.labeling?
        return failure("only the operator who started the evaluation is its sole reference judge") unless @actor&.id == @evaluation.created_by_id

        @corpus_case = @evaluation.corpus.find_case(@case_id)
        return failure("case #{@case_id.inspect} is not part of the frozen corpus") unless @corpus_case
        unless skip?
          return failure("the cited evidence must be one of #{case_evidence_references.join(', ')}") unless case_evidence_references.include?(cited_evidence_reference)
        end

        persist(build_label(@evaluation.labels.find_or_initialize_by(case_id: @case_id)))
      rescue ActiveRecord::RecordNotUnique
        # A double-submit of the same case races find_or_initialize_by: both
        # requests build a new row and the loser's insert hits the unique
        # (evaluation, case_id) index. The winner's row is the durable
        # save/resume state, so the loser retries once as an in-place update
        # instead of surfacing the index race as a 500.
        persist(build_label(@evaluation.labels.find_by!(case_id: @case_id)))
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def persist(label)
        return failure(label.errors.full_messages.to_sentence) unless label.save

        log_recorded(label)
        Result.new(success: true, error: nil, label: label)
      end

      def build_label(label)
        if skip?
          label.state = "skipped"
          label.verdict = nil
          label.intent_band = nil
          label.technical_band = nil
          label.readiness = nil
          label.cited_evidence_reference = nil
          label.reason = nil
        else
          label.state = "labeled"
          label.verdict = judgment.fetch(:verdict).presence
          label.intent_band = judgment.fetch(:intent_band).presence
          label.technical_band = judgment.fetch(:technical_band).presence
          label.readiness = judgment.fetch(:readiness).presence
          label.cited_evidence_reference = cited_evidence_reference
          label.reason = judgment.fetch(:reason).to_s.strip
        end
        label.recorded_by = @actor
        label.recorded_at = Time.current
        label
      end

      def skip?
        judgment.nil?
      end

      def cited_evidence_reference
        judgment.fetch(:cited_evidence_reference).to_s.strip
      end

      def case_evidence_references
        @corpus_case.fetch("evidence").map { |item| item.fetch("reference") }
      end

      def log_recorded(label)
        Rails.logger.info(
          message: "facet_confidence.reference_judgment_recorded",
          project_id: @evaluation.project_id,
          facet_confidence_evaluation_id: @evaluation.id,
          case_id: @case_id,
          state: label.state,
          actor_user_id: @actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, label: nil)
      end
    end
  end
end
