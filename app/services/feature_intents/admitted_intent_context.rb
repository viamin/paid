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
        "design_baseline" => feature_intent.approved_design_revision,
        "facets" => applicable_facets.map { |facet| facet_snapshot(facet) }
      }
    end

    private

    attr_reader :issue

    def feature_intent
      @feature_intent ||= FeatureIntent.joins(:feature_intent_issues)
        .find_by(feature_intent_issues: { issue_id: issue.id })
    end

    def applicable_facets
      FeatureIntentFacet.where(feature_intent: feature_intent).where(issue_id: [ nil, issue.id ])
    end

    def facet_snapshot(facet)
      direction = facet.directions.where(status: "active").order(:id).first
      assessment = current_assessment(direction, facet.evidence_revision)
      {
        "name" => facet.name,
        "design_claim" => facet.design_claim,
        "direction" => direction&.name,
        "evidence_revision" => facet.evidence_revision,
        "intent_score" => assessment&.intent_score,
        "technical_score" => assessment&.technical_score,
        "inferred_fit" => assessment&.explanation,
        "expressed_intent" => expressed_intent(facet, direction),
        "demonstrated_feasibility" => demonstrated_feasibility(facet, direction)
      }
    end

    def current_assessment(direction, revision)
      direction&.assessments&.where(evidence_revision: revision, status: "completed")&.order(created_at: :desc)&.first
    end

    def expressed_intent(facet, direction)
      evidence_for(facet, direction, "human_statement")
    end

    def demonstrated_feasibility(facet, direction)
      evidence_for(facet, direction, "repository_fact") + evidence_for(facet, direction, "experiment_result")
    end

    def evidence_for(facet, direction, source_type)
      relation = facet.evidence.where(evidence_revision: facet.evidence_revision, source_type: source_type)
      relation = relation.where(feature_intent_facet_direction: direction) if direction
      relation.order(:id).pluck(:statement)
    end
  end
end
