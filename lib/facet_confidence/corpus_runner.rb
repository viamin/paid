# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "assessment_corpus_ledger"

module FacetConfidence
  # Executes the frozen RDR-070 corpus through the shipped assessment prompt
  # and records either a provenance-complete verdict or an operational failure.
  # @spec FACET-CONFIDENCE-017 FACET-CONFIDENCE-018
  class CorpusRunner
    Result = Data.define(:attempted, :completed, :failed)

    def self.call(...) = new(...).call

    def initialize(corpus_path:, ledger_path:, agent_harness: AgentHarness, recorded_at: -> { Time.current })
      @corpus_path = corpus_path
      @ledger_path = ledger_path
      @agent_harness = agent_harness
      @recorded_at = recorded_at
    end

    def call
      cases = AssessmentCorpusLedger.load_corpus(corpus_path)
      results = pending_cases(cases).map { |corpus_case| record(run(corpus_case)) }
      Result.new(attempted: results.length, completed: results.count { |event| event.fetch("status") == "completed" },
        failed: results.count { |event| event.fetch("status") == "failed" })
    end

    private

    attr_reader :agent_harness, :corpus_path, :ledger_path, :recorded_at

    def pending_cases(cases)
      evaluated = AssessmentCorpusLedger.evaluate(corpus_path:, ledger_path:)
      cases.select do |corpus_case|
        latest_run = evaluated.fetch(corpus_case.fetch("id")).fetch(:runs).last
        latest_run.nil? || latest_run.fetch("status") == "failed"
      end
    end

    def run(corpus_case)
      response = agent_harness.send_message(prompt(corpus_case), provider: :claude, model: corpus_case.fetch("model_version"),
        timeout: FeatureIntents::AssessFacet::TIMEOUT, tools: :none, **Llm::TextMode.options)
      return failed_event(corpus_case) unless response.respond_to?(:success?) && response.success?

      event_for(corpus_case, payload(response.output), cost_cents(response))
    rescue AgentHarness::Error
      failed_event(corpus_case)
    end

    def payload(output)
      JSON.parse(output.to_s).slice("status", "intent_score", "technical_score", "evidence_references")
    rescue JSON::ParserError
      {}
    end

    def event_for(corpus_case, result, cost_cents)
      return failed_event(corpus_case, cost_cents:) unless valid_result?(corpus_case, result)

      identity(corpus_case).merge(result).merge("cost_cents" => cost_cents)
    end

    def valid_result?(corpus_case, result)
      status = result["status"]
      return false unless AssessmentCorpusLedger::EXPECTED_STATUSES.include?(status)
      return false unless Array(result["evidence_references"]).all? { |reference| references(corpus_case).include?(reference) }

      status != "completed" || [ result["intent_score"], result["technical_score"] ].all? { |score| score.is_a?(Integer) && score.between?(0, 100) }
    end

    def failed_event(corpus_case, cost_cents: 0)
      identity(corpus_case).merge("status" => "failed", "intent_score" => nil, "technical_score" => nil,
        "evidence_references" => [], "cost_cents" => cost_cents)
    end

    def identity(corpus_case)
      { "event_id" => "assessment-run-#{corpus_case.fetch('id')}-#{SecureRandom.uuid}", "recorded_at" => recorded_at.call.iso8601,
        "type" => "assessment_run", "case_id" => corpus_case.fetch("id"), "rubric_version" => corpus_case.fetch("rubric_version"),
        "model_version" => corpus_case.fetch("model_version"), "input_revision" => corpus_case.fetch("evidence_revision") }
    end

    def references(corpus_case)
      corpus_case.fetch("evidence").map { |evidence| evidence.fetch("reference") }
    end

    def cost_cents(response)
      cost = response.cost_cents if response.respond_to?(:cost_cents)
      cost.is_a?(Integer) && cost >= 0 ? cost : 0
    end

    def record(event)
      AssessmentCorpusLedger.append!(ledger_path:, event:, corpus_path:)
      event
    end

    def prompt(corpus_case)
      <<~PROMPT
        Assess this frozen facet-confidence corpus case using rubric #{corpus_case.fetch("rubric_version")}.
        Return only JSON with status, intent_score, technical_score, and evidence_references.
        status is completed, clarification_needed, or unknown. Completed requires both integer scores from 0 to 100.
        Intent certainty and technical confidence are independent. Unknown intent is never readiness. Do not count repeated agent suggestions or UI interaction as human agreement. Explicit corrections supersede prior evidence; collaborator disagreement requires clarification.

        Corpus case: #{JSON.generate(corpus_case.slice("facet", "direction", "evidence", "thresholds"))}
      PROMPT
    end
  end
end
