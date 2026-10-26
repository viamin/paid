# frozen_string_literal: true

require "securerandom"

module FacetConfidence
  # Replays the frozen corpus through the shipped facet assessment service and
  # retains the resulting operational evidence in the append-only ledger.
  # @spec FACET-CONFIDENCE-017 FACET-CONFIDENCE-018 FACET-CONFIDENCE-022
  class CorpusRunner
    Result = Data.define(:case_id, :assessment_status)

    def self.call(...) = new(...).call

    def initialize(project:, corpus_path: self.class.corpus_path, ledger_path: self.class.ledger_path, assessor: FeatureIntents::AssessFacet)
      @project = project
      @corpus_path = corpus_path
      @ledger_path = ledger_path
      @assessor = assessor
    end

    def self.ledger_path
      Rails.root.join("docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl")
    end

    def self.corpus_path
      Rails.root.join("docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml")
    end

    def call
      TenantContext.with_system_access do
        AssessmentCorpusLedger.load_corpus(corpus_path).map { |corpus_case| run_case(corpus_case) }
      end
    end

    private

    attr_reader :assessor, :corpus_path, :ledger_path, :project

    def run_case(corpus_case)
      assessment = create_assessment(corpus_case)
      assessor.call(assessment:)
      assessment.reload
      AssessmentCorpusLedger.append!(corpus_path:, ledger_path:, event: ledger_event(corpus_case, assessment))
      Result.new(case_id: corpus_case.fetch("id"), assessment_status: assessment.status)
    end

    def create_assessment(corpus_case)
      facet = create_facet(corpus_case)
      direction = facet.directions.create!(account: project.account, **corpus_case.fetch("direction"))
      create_evidence(facet, direction, corpus_case.fetch("evidence"))
      direction.assessments.create!(account: project.account, evidence_revision: facet.evidence_revision,
        status: "pending", rubric_version: corpus_case.fetch("rubric_version"), model_version: corpus_case.fetch("model_version"))
    end

    def create_facet(corpus_case)
      feature = FeatureIntent.create!(project:, title: "RDR-070 corpus #{corpus_case.fetch('id')}",
        brief: "Frozen facet-confidence assessment corpus evaluation.")
      feature.facets.create!(account: project.account, **corpus_case.fetch("facet"))
    end

    def create_evidence(facet, direction, entries)
      recorded = entries.sort_by { |entry| entry.fetch("occurred_at") }.map.with_index do |entry, index|
        facet.evidence.create!(account: project.account, feature_intent_facet_direction: direction,
          source_type: entry.fetch("source_type"), source_reference: entry.fetch("reference"),
          idempotency_key: "rdr-070-corpus:#{SecureRandom.uuid}:#{entry.fetch('reference')}",
          statement: entry.fetch("statement"), occurred_at: entry.fetch("occurred_at"), evidence_revision: index + 1)
      end
      facet.update!(evidence_revision: recorded.length)
      recorded.each_with_index do |evidence, index|
        superseded_reference = entries.sort_by { |entry| entry.fetch("occurred_at") }[index]["supersedes"]
        evidence_by_reference(recorded).fetch(superseded_reference).update!(superseded_by: evidence) if superseded_reference
      end
    end

    def evidence_by_reference(evidence) = evidence.index_by(&:source_reference)

    def ledger_event(corpus_case, assessment)
      { "event_id" => "assessment-run-#{corpus_case.fetch('id')}-#{SecureRandom.uuid}", "recorded_at" => Time.current.iso8601,
        "type" => "assessment_run", "case_id" => corpus_case.fetch("id"), "rubric_version" => assessment.rubric_version,
        "model_version" => assessment.model_version, "input_revision" => assessment.evidence_revision,
        "status" => ledger_status(assessment), "intent_score" => assessment.intent_score,
        "technical_score" => assessment.technical_score, "evidence_references" => assessment.evidence_references,
        "cost_cents" => 0 }
    end

    def ledger_status(assessment)
      return assessment.status if AssessmentCorpusLedger::RUN_STATUSES.include?(assessment.status)

      "failed"
    end
  end
end
