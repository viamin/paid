# frozen_string_literal: true

require "securerandom"

module FacetConfidence
  # Replays the frozen RDR-070 corpus through the shipped facet assessor and
  # appends one provenance-complete result for every case. This operator-only
  # measurement never changes a project's readiness configuration.
  # @spec FACET-CONFIDENCE-017 FACET-CONFIDENCE-018
  class RunCorpus
    CORPUS_PATH = Rails.root.join("docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml").freeze
    LEDGER_PATH = Rails.root.join("docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl").freeze

    def self.call(...) = new(...).call

    def initialize(project_id:, corpus_path: CORPUS_PATH, ledger_path: LEDGER_PATH)
      @project_id = project_id
      @corpus_path = corpus_path
      @ledger_path = ledger_path
    end

    def call
      TenantContext.with_system_access do
        project = Project.find(project_id)
        TenantContext.with(project.account) { run_cases(project) }
      end
    end

    private

    attr_reader :corpus_path, :ledger_path, :project_id

    def run_cases(project)
      AssessmentCorpusLedger.load_corpus(corpus_path).map { |corpus_case| run_case(project, corpus_case) }
    end

    def run_case(project, corpus_case)
      assessment = assess(project, corpus_case)
      event = assessment_event(corpus_case, assessment)
      AssessmentCorpusLedger.append!(ledger_path:, event:, corpus_path:)
      event
    end

    def assess(project, corpus_case)
      facet = create_facet(project, corpus_case)
      direction = create_direction(facet, corpus_case)
      create_evidence(facet, direction, corpus_case)
      assessment = direction.assessments.create!(account: project.account, evidence_revision: facet.reload.evidence_revision,
        status: "pending", rubric_version: FeatureIntents::AssessFacet::RUBRIC_VERSION,
        model_version: FeatureIntents::AssessFacet::MODEL_VERSION)
      FeatureIntents::AssessFacet.call(assessment:)
    end

    def create_facet(project, corpus_case)
      feature = FeatureIntent.create!(project:, title: "RDR-070 corpus #{corpus_case.fetch('id')}",
        brief: "Frozen facet-confidence corpus measurement.", status: "discovering")
      feature.facets.create!(account: project.account, name: corpus_case.dig("facet", "name"),
        design_claim: corpus_case.dig("facet", "design_claim"))
    end

    def create_direction(facet, corpus_case)
      facet.directions.create!(account: facet.account, name: corpus_case.dig("direction", "name"),
        description: corpus_case.dig("direction", "description"))
    end

    def create_evidence(facet, direction, corpus_case)
      evidence = corpus_case.fetch("evidence").map.with_index do |item, index|
        facet.evidence.create!(account: facet.account, feature_intent_facet_direction: direction,
          idempotency_key: "rdr-070:#{corpus_case.fetch('id')}:#{item.fetch('reference')}:#{SecureRandom.uuid}",
          source_type: item.fetch("source_type"), source_reference: item.fetch("reference"),
          statement: item.fetch("statement"), occurred_at: item.fetch("occurred_at"), evidence_revision: index + 1)
      end
      evidence.each do |item|
        superseded = corpus_case.fetch("evidence").find { |source| source["reference"] == item.source_reference }&.fetch("supersedes", nil)
        item.update!(superseded_by: evidence.find { |candidate| candidate.source_reference == superseded }) if superseded
      end
      facet.update!(evidence_revision: evidence.length)
    end

    def assessment_event(corpus_case, assessment)
      { "event_id" => "assessment-run-#{corpus_case.fetch('id')}-#{assessment.id}", "recorded_at" => Time.current.iso8601,
        "type" => "assessment_run", "case_id" => corpus_case.fetch("id"),
        "rubric_version" => assessment.rubric_version, "model_version" => assessment.model_version,
        "input_revision" => assessment.evidence_revision, "status" => assessment.status,
        "intent_score" => assessment.intent_score, "technical_score" => assessment.technical_score,
        "evidence_references" => assessment.evidence_references, "cost_cents" => 0,
        "failure_reason" => assessment.status == "failed" ? assessment.explanation : nil }.compact
    end
  end
end
