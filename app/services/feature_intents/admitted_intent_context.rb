# frozen_string_literal: true

module FeatureIntents
  # Captures the policy-scoped intent that an implementation run was admitted
  # against. The snapshot is deliberately data-only: later assessment work
  # must not revise an active builder's scope.
  # @spec FACET-CONFIDENCE-013 @spec FACET-CONFIDENCE-015
  # @spec CONFIDENCE-DELIVERY-007 @spec CONFIDENCE-DELIVERY-010
  class AdmittedIntentContext
    def self.capture(...) = new(...).capture

    def initialize(issue:)
      @issue = issue
    end

    def capture
      return {} unless feature_intent&.confidence_driven?

      {
        "policy" => feature_intent.delivery_policy,
        "feature_id" => feature_intent.id,
        "issue_id" => issue.id,
        "design_baseline" => issue_link.release_snapshot["merged_baseline"],
        "design_document_paths" => Array(issue_link.current_readiness_mapping["design_artifacts"]).filter_map { |artifact| artifact["path"] },
        "facets" => applicable_facets.flat_map { |facet| facet_snapshot(facet) }
      }
    end

    private

    attr_reader :issue

    def feature_intent
      issue_link&.feature_intent
    end

    def issue_link
      @issue_link ||= FeatureIntentIssue.joins(:feature_intent).includes(:feature_intent, :prerequisite_mapping)
        .find_by(issue_id: issue.id, feature_intents: { delivery_policy: "confidence_driven" })
    end

    def applicable_facets
      FeatureIntentFacet.where(feature_intent: feature_intent).where(issue_id: [ nil, issue.id ])
    end

    def facet_snapshot(facet)
      directions = facet.directions.where(status: "active").order(:id)
      directions = [ nil ] if directions.empty?
      directions.map { |direction| direction_snapshot(facet, direction) }
    end

    def direction_snapshot(facet, direction)
      assessment = current_assessment(direction, facet.evidence_revision)
      {
        "name" => facet.name, "design_claim" => facet.design_claim,
        "direction" => direction&.name, "evidence_revision" => facet.evidence_revision,
        "intent_score" => assessment&.intent_score, "technical_score" => assessment&.technical_score,
        "inferred_fit" => assessment&.inferred_fit,
        "expressed_intent" => evidence_for(facet, direction, %w[human_statement human_correction]),
        "demonstrated_feasibility" => evidence_for(facet, direction, %w[repository_fact experiment_result])
      }
    end

    def current_assessment(direction, revision)
      direction&.assessments&.where(evidence_revision: revision, status: "completed")&.order(created_at: :desc)&.first
    end

    def evidence_for(facet, direction, source_types)
      relation = facet.evidence.where(evidence_revision: facet.evidence_revision, source_type: source_types, superseded_by: nil)
      relation = relation.where(feature_intent_facet_direction: direction) if direction
      relation.order(:id).pluck(:statement)
    end
  end
end
