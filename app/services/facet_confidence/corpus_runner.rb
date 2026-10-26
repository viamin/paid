# frozen_string_literal: true

require "securerandom"
require "set"

module FacetConfidence
  # Executes the frozen corpus through FeatureIntents::AssessFacet and records
  # the resulting provider outcome in the append-only evaluation ledger.
  # @spec FACET-CONFIDENCE-016 @spec FACET-CONFIDENCE-017 @spec FACET-CONFIDENCE-018
  class CorpusRunner
    CORPUS_PATH = Rails.root.join("docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml").freeze
    LEDGER_PATH = Rails.root.join("docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl").freeze

    def self.call(...) = new(...).call

    def initialize(project:, corpus_path: CORPUS_PATH, ledger_path: LEDGER_PATH)
      @project = project
      @corpus_path = corpus_path
      @ledger_path = ledger_path
    end

    def call
      AssessmentCorpusLedger.load_corpus(corpus_path).reject { |corpus_case| recorded_case_ids.include?(corpus_case.fetch("id")) }.map do |corpus_case|
        run_case(corpus_case)
      end
    end

    private

    attr_reader :corpus_path, :ledger_path, :project

    def recorded_case_ids
      @recorded_case_ids ||= AssessmentCorpusLedger.events(ledger_path).filter_map do |event|
        event["case_id"] if event["type"] == "assessment_run"
      end.to_set
    end

    def run_case(corpus_case)
      assessment = build_assessment(corpus_case)
      result = FeatureIntents::AssessFacet.call(assessment: assessment)
      event = event_for(corpus_case, result)
      AssessmentCorpusLedger.append!(ledger_path:, corpus_path:, event:)
      event
    ensure
      facet = assessment&.feature_intent_facet_direction&.feature_intent_facet
      feature_intent = facet&.feature_intent
      assessment&.destroy!
      FeatureIntentFacetEvidence.where(feature_intent_facet: facet).delete_all if facet
      feature_intent&.destroy!
    end

    def build_assessment(corpus_case)
      feature_intent = FeatureIntent.create!(
        project: project,
        title: "Corpus assessment #{corpus_case.fetch('id')}",
        brief: "Ephemeral frozen RDR-070 corpus input.",
        status: "discovering",
        criteria_clarity_state: "pending",
        delivery_policy: "approval_gated"
      )
      facet = feature_intent.facets.create!(account: project.account, **corpus_case.fetch("facet").symbolize_keys)
      direction = facet.directions.create!(account: project.account, **corpus_case.fetch("direction").symbolize_keys)
      evidence_for(corpus_case, facet, direction)
      direction.assessments.create!(
        account: project.account,
        evidence_revision: facet.reload.evidence_revision,
        status: "pending",
        rubric_version: FeatureIntents::AssessFacet::RUBRIC_VERSION,
        model_version: FeatureIntents::AssessFacet::MODEL_VERSION
      )
    end

    def evidence_for(corpus_case, facet, direction)
      previous = {}
      corpus_case.fetch("evidence").each do |item|
        evidence = facet.evidence.create!(
          account: project.account,
          feature_intent_facet_direction: direction,
          idempotency_key: "corpus-#{SecureRandom.uuid}",
          source_type: item.fetch("source_type"),
          source_reference: item.fetch("reference"),
          statement: item.fetch("statement"),
          occurred_at: item.fetch("occurred_at"),
          evidence_revision: facet.evidence_revision + 1
        )
        facet.update!(evidence_revision: evidence.evidence_revision)
        previous.fetch(item["supersedes"]).update!(superseded_by: evidence) if item["supersedes"]
        previous[item.fetch("reference")] = evidence
      end
    end

    def event_for(corpus_case, result)
      {
        "event_id" => "assessment-run-#{corpus_case.fetch('id')}-#{SecureRandom.uuid}",
        "recorded_at" => Time.current.iso8601,
        "type" => "assessment_run",
        "case_id" => corpus_case.fetch("id"),
        "rubric_version" => FeatureIntents::AssessFacet::RUBRIC_VERSION,
        "model_version" => FeatureIntents::AssessFacet::MODEL_VERSION,
        "input_revision" => corpus_case.fetch("evidence_revision"),
        "status" => ledger_status(result),
        "intent_score" => result.intent_score,
        "technical_score" => result.technical_score,
        "evidence_references" => result.evidence_references || [],
        "cost_cents" => 0
      }
    end

    def ledger_status(result)
      return "failed" if result.status == "failed"
      return "completed" if result.status == "completed"

      "unknown"
    end
  end
end
