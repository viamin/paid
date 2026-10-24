# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Blinded serialization of one corpus case for the labeling screen.
    # While labels are unfrozen this view structurally cannot leak answers:
    # the preassigned stratum, any expected-label hint, and reviewer outputs
    # are excluded from the field whitelist. The maintainer's own recorded
    # input for the case is included so save/resume works.
    # @spec INTENT-CONFORMANCE-ROLLOUT-006
    class CaseView
      BLIND_FIELDS = %w[id repository base_sha head_sha approved_design_revision].freeze
      # Corpus selection rationale, free-text notes, and arbitrary context can
      # encode the expected outcome. The blinded surface exposes only declared
      # design artifact paths, which the evidence action validates separately.
      CONTEXT_FIELDS = %w[design_document_paths].freeze

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
        CONTEXT_FIELDS.each { |field| payload[field] = @corpus_case[field] if @corpus_case.key?(field) }
        payload["label"] = actor_may_view_label? ? own_label&.then { |label| { "state" => label.state, "outcome" => label.outcome, "cited_design_claim" => label.cited_design_claim, "reason" => label.reason } } : nil
        payload
      end

      def own_label
        @evaluation.labels.find_by(case_id: @corpus_case.fetch("id"))
      end

      # Pre-freeze, only the declared maintainer may see saved labels — any
      # other account member hitting this URL with a labeled case_id must
      # not receive the outcome, citation, or reason. Post-freeze the
      # blinding boundary is gone, so every viewer sees the same payload.
      def actor_may_view_label?
        @evaluation.answers_visible? || @evaluation.solo_maintainer_id == @actor&.id
      end

      # Next case needing attention: the first case that is neither labeled
      # nor skipped, so a fresh session starts at the top and a resumed
      # session picks up where the maintainer left off.
      def self.next_pending_case_id(evaluation)
        done = evaluation.labels.where(state: %w[labeled skipped]).pluck(:case_id).index_with { true }
        evaluation.corpus.case_ids.find { |case_id| !done[case_id] }
      end

      # Progress by count only: strata distribution stays hidden pre-freeze.
      def self.progress(evaluation)
        {
          total: evaluation.corpus.case_ids.length,
          labeled: evaluation.labels.where(state: "labeled").count,
          skipped: evaluation.labels.where(state: "skipped").count
        }
      end
    end
  end
end
