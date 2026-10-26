# frozen_string_literal: true

require "json"

module FacetConfidence
  # Executes the frozen corpus through the same pinned agent-harness contract
  # used by facet assessments and records either a verdict or an operational
  # failure. It never substitutes a provider or model.
  # @spec FACET-CONFIDENCE-017 @spec FACET-CONFIDENCE-018
  class CorpusRunner
    MANIFEST_PATH = "docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml"
    LEDGER_PATH = "docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl"
    TIMEOUT = 60

    def self.call(...) = new(...).call

    def initialize(project:, corpus_path: Rails.root.join(MANIFEST_PATH), ledger_path: Rails.root.join(LEDGER_PATH), agent_harness: AgentHarness, clock: -> { Time.current })
      @project = project
      @corpus_path = corpus_path.to_s
      @ledger_path = ledger_path.to_s
      @agent_harness = agent_harness
      @clock = clock
    end

    def call
      AssessmentCorpusLedger.load_corpus(corpus_path).each { |corpus_case| record(corpus_case) }
    end

    private

    attr_reader :agent_harness, :clock, :corpus_path, :ledger_path, :project

    def record(corpus_case)
      AssessmentCorpusLedger.append!(ledger_path:, corpus_path:, event: event_for(corpus_case))
    rescue AgentHarness::Error => error
      AssessmentCorpusLedger.append!(ledger_path:, corpus_path:, event: failed_event(corpus_case, error.class.name))
    end

    def event_for(corpus_case)
      response = agent_harness.send_message(prompt(corpus_case), provider: :claude, model: corpus_case.fetch("model_version"), timeout: TIMEOUT,
        tools: :none, **Llm::TextMode.options)
      return failed_event(corpus_case, "provider_unavailable") unless response.respond_to?(:success?) && response.success?
      return failed_event(corpus_case, "provider_model_mismatch") unless response_model(response) == corpus_case.fetch("model_version")

      payload = JSON.parse(response.output.to_s).deep_stringify_keys
      valid_payload!(payload, corpus_case)
      run_event(corpus_case, payload, response)
    rescue JSON::ParserError, ArgumentError => error
      failed_event(corpus_case, error.class.name)
    end

    def run_event(corpus_case, payload, response)
      base_event(corpus_case).merge("status" => payload.fetch("status"), "intent_score" => payload["intent_score"],
        "technical_score" => payload["technical_score"], "evidence_references" => payload.fetch("evidence_references"),
        "cost_cents" => response_cost(response))
    end

    def failed_event(corpus_case, reason)
      base_event(corpus_case).merge("status" => "failed", "intent_score" => nil, "technical_score" => nil,
        "evidence_references" => [], "cost_cents" => 0, "failure_reason" => reason)
    end

    def base_event(corpus_case)
      { "event_id" => "run-#{corpus_case.fetch('id')}-#{clock.call.utc.iso8601(6)}", "recorded_at" => clock.call.utc.iso8601,
        "type" => "assessment_run", "case_id" => corpus_case.fetch("id"), "rubric_version" => corpus_case.fetch("rubric_version"),
        "model_version" => corpus_case.fetch("model_version"), "input_revision" => corpus_case.fetch("evidence_revision") }
    end

    def response_model(response)
      response.respond_to?(:model) ? response.model.to_s : response.metadata.to_h["model"].to_s
    end

    def response_cost(response)
      Integer(response.respond_to?(:cost_cents) ? response.cost_cents : response.metadata.to_h.fetch("cost_cents", 0))
    rescue ArgumentError, TypeError
      0
    end

    def valid_payload!(payload, corpus_case)
      statuses = AssessmentCorpusLedger::EXPECTED_STATUSES
      references = corpus_case.fetch("evidence").map { |evidence| evidence.fetch("reference") }
      raise ArgumentError unless statuses.include?(payload["status"]) && Array(payload["evidence_references"]).all? { |reference| references.include?(reference) }
      return unless payload["status"] == "completed" && (!payload["intent_score"].is_a?(Integer) || !payload["technical_score"].is_a?(Integer))

      raise ArgumentError
    end

    def prompt(corpus_case)
      <<~PROMPT
        Assess the active candidate direction using rubric #{corpus_case.fetch("rubric_version")}. Intent certainty and technical confidence are independent 0-100 integer policy assessments, not calibrated probabilities. Unknown is null. Do not count duplicate evidence or repeated agent suggestions; explicit corrections supersede older evidence; collaborator conflict requires clarification.
        Return JSON with status, intent_score, technical_score, and evidence_references. status is completed, clarification_needed, or unknown. Use only supplied evidence references.
        Project: #{project.id}
        Facet: #{corpus_case.dig("facet", "name")}
        Design claim: #{corpus_case.dig("facet", "design_claim")}
        Direction: #{corpus_case.dig("direction", "name")}: #{corpus_case.dig("direction", "description")}
        Evidence: #{JSON.generate(corpus_case.fetch("evidence"))}
      PROMPT
    end
  end
end
