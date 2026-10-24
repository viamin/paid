# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Blinded serialization of one frozen corpus case for the
    # reference-judgment screen. While judgments are unfrozen this view
    # structurally cannot leak the answers: the case shape, the selection
    # rationale, and the frozen expected bands are excluded from the field
    # whitelist. The judge's own recorded judgment for the case is included so
    # save/resume works.
    # @spec FACET-CONFIDENCE-021
    class CaseView
      BLIND_FIELDS = %w[id facet direction evidence thresholds].freeze

      def initialize(evaluation:, case_id:, actor:)
        @evaluation = evaluation
        @corpus_case = evaluation.corpus.find_case(case_id)
        @actor = actor
      end

      def exists?
        !@corpus_case.nil?
      end

      def blinded_payload
        return nil unless @corpus_case

        payload = @corpus_case.slice(*BLIND_FIELDS)
        payload["label"] = actor_may_view_label? ? own_label_payload : nil
        payload
      end

      def own_label
        @evaluation.labels.find_by(case_id: @corpus_case.fetch("id"))
      end

      # Pre-freeze, only the judge may see saved judgments — any other account
      # member hitting this URL with a judged case_id must not receive the
      # verdict, bands, citation, or reason. Post-freeze the blinding boundary
      # is gone, so every viewer sees the same payload.
      def actor_may_view_label?
        @evaluation.answers_visible? || @evaluation.created_by_id == @actor&.id
      end

      # Next case needing attention: the first case that is neither labeled
      # nor skipped, so a fresh session starts at the top and a resumed
      # session picks up where the judge left off.
      def self.next_pending_case_id(evaluation)
        done = evaluation.labels.where(state: %w[labeled skipped]).pluck(:case_id).index_with { true }
        evaluation.corpus.case_ids.find { |case_id| !done[case_id] }
      end

      # Progress by count only: the shape distribution stays hidden pre-freeze.
      def self.progress(evaluation)
        {
          total: evaluation.corpus.case_ids.length,
          labeled: evaluation.labels.where(state: "labeled").count,
          skipped: evaluation.labels.where(state: "skipped").count
        }
      end

      private

      def own_label_payload
        own_label&.then do |label|
          { "state" => label.state, "verdict" => label.verdict, "intent_band" => label.intent_band,
            "technical_band" => label.technical_band, "readiness" => label.readiness,
            "cited_evidence_reference" => label.cited_evidence_reference, "reason" => label.reason }
        end
      end
    end
  end
end
