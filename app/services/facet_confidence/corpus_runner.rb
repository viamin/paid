# frozen_string_literal: true

require "securerandom"

module FacetConfidence
  # Executes the frozen corpus through FeatureIntents::AssessFacet and records
  # the resulting provider outcome in the append-only evaluation ledger.
  # @spec FACET-CONFIDENCE-016 @spec FACET-CONFIDENCE-017 @spec FACET-CONFIDENCE-018
  class CorpusRunner
    PinnedModelMismatch = Class.new(StandardError)
    CostUnavailable = Class.new(StandardError)

    CORPUS_PATH = Rails.root.join("docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml").freeze
    LEDGER_PATH = Rails.root.join("docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl").freeze

    def self.call(...) = new(...).call

    def initialize(project:, corpus_path: CORPUS_PATH, ledger_path: LEDGER_PATH)
      @project = project
      @corpus_path = corpus_path
      @ledger_path = ledger_path
    end

    def call
      corpus_cases = AssessmentCorpusLedger.load_corpus(corpus_path)
      ensure_assessor_model!(corpus_cases)

      AssessmentCorpusLedger.with_ledger_lock(ledger_path) do
        corpus_cases.filter_map do |corpus_case|
          run_case(corpus_case) unless covered_case_ids.include?(corpus_case.fetch("id"))
        end
      end
    end

    private

    attr_reader :corpus_path, :ledger_path, :project

    def covered_case_ids
      assessment_runs.filter_map do |event|
        event["case_id"] unless event["status"] == "failed"
      end
    end

    def ensure_assessor_model!(corpus_cases)
      corpus_models = corpus_cases.map { |corpus_case| corpus_case.fetch("model_version") }.uniq
      return if corpus_models == [ FeatureIntents::AssessFacet::MODEL_VERSION ]

      raise PinnedModelMismatch, "frozen corpus model #{corpus_models.join(', ')} does not match assessor model #{FeatureIntents::AssessFacet::MODEL_VERSION}"
    end

    def run_case(corpus_case)
      assessment = build_assessment(corpus_case)
      assessor = FeatureIntents::AssessFacet.new(assessment: assessment)
      result = assessor.call
      event = event_for(corpus_case, result, response_status: assessor.response_status, cost_cents: cost_cents_for!(assessor, result),
        retry_of_event_id: failed_run_event_ids[corpus_case.fetch("id")])
      AssessmentCorpusLedger.append_locked!(ledger_path:, corpus_path:, event:)
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
          textual_context: "Corpus actor role: #{item.fetch('actor_role')}.",
          occurred_at: item.fetch("occurred_at"),
          evidence_revision: facet.evidence_revision + 1
        )
        facet.update!(evidence_revision: evidence.evidence_revision)
        previous.fetch(item["supersedes"]).update!(superseded_by: evidence) if item["supersedes"]
        previous[item.fetch("reference")] = evidence
      end
    end

    def assessment_runs
      AssessmentCorpusLedger.events(ledger_path).select { |event| event["type"] == "assessment_run" }
    end

    def failed_run_event_ids
      assessment_runs.each_with_object({}) do |event, event_ids|
        event_ids[event.fetch("case_id")] = event.fetch("event_id") if event["status"] == "failed"
      end
    end

    def event_for(corpus_case, result, response_status:, cost_cents:, retry_of_event_id:)
      {
        "event_id" => "assessment-run-#{corpus_case.fetch('id')}-#{SecureRandom.uuid}",
        "recorded_at" => Time.current.iso8601,
        "type" => "assessment_run",
        "case_id" => corpus_case.fetch("id"),
        "rubric_version" => FeatureIntents::AssessFacet::RUBRIC_VERSION,
        "model_version" => FeatureIntents::AssessFacet::MODEL_VERSION,
        "input_revision" => corpus_case.fetch("evidence_revision"),
        "status" => ledger_status(result, response_status),
        "retry_of_event_id" => retry_of_event_id,
        "intent_score" => result.intent_score,
        "technical_score" => result.technical_score,
        "evidence_references" => result.evidence_references || [],
        "cost_cents" => cost_cents
      }.compact
    end

    def cost_cents_for!(assessor, result)
      cost = assessor.cost_cents
      return cost if cost.is_a?(Integer) && cost >= 0
      return 0 if result.status == "failed"

      raise CostUnavailable, "assessment cost provenance is unavailable"
    end

    def ledger_status(result, response_status)
      return "failed" if result.status == "failed"

      response_status || result.status
    end
  end
end
