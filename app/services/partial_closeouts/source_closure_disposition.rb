# frozen_string_literal: true

module PartialCloseouts
  # The only authority for a source issue closing reference. Semantic
  # assessment arrives through Llm::AnalyzePartialCloseout; this object only
  # validates that its criterion-level result still describes current evidence.
  # @spec PARTIAL-CLOSEOUT-029
  class SourceClosureDisposition
    CLOSE = "close"
    TRACK = "track"

    def self.call(...) = new(...).call

    def self.record!(agent_run, assessment:)
      result = call(issue: agent_run.issue, assessment: assessment)
      agent_run.update!(reconciliation: agent_run.reconciliation.merge("source_closure" => result))
      result
    end

    def self.for(agent_run)
      assessment = agent_run.reconciliation.to_h.fetch("assessment", {})
      current = call(issue: agent_run.issue, assessment: assessment)
      recorded = agent_run.reconciliation.dig("source_closure", "disposition")
      current.merge("disposition" => recorded == CLOSE && current["disposition"] == CLOSE ? CLOSE : TRACK)
    end

    def initialize(issue:, assessment:)
      @issue = issue
      @assessment = assessment.to_h.deep_stringify_keys
    end

    def call
      {
        "disposition" => closes? ? CLOSE : TRACK,
        "source_revision" => assessment["source_revision"],
        "intent_revision" => assessment["intent_revision"],
        "assessed_at" => assessment["assessed_at"]
      }
    end

    private

    attr_reader :issue, :assessment

    def closes?
      issue.present? && current_revisions? && gaps.empty? && criteria.present? && criteria.all? { |criterion| criterion["state"] == "satisfied" }
    end

    def current_revisions?
      assessment["source_revision"] == Issues::CloseoutEvidence.call(issue).digest &&
        assessment["intent_revision"] == Assessment.intent_revision_for(issue)
    end

    def gaps = Array(assessment["gaps"])

    def criteria
      raw = assessment["criteria"]
      raw.is_a?(Array) && raw.all?(Hash) ? raw : []
    end
  end
end
