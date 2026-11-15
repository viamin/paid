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
      call(issue: agent_run.issue, assessment: assessment)
    end

    # A source PR has an additional freshness boundary: closeout evidence is
    # useful only for the exact commit that GitHub is about to merge.  The
    # regular publication path deliberately has no head yet, so retain its
    # existing behavior and apply this stricter rule only at the merge edge.
    def self.for_pull_request(issue:, assessment:, head_sha:, verification_revision:)
      new(issue:, assessment:, head_sha:, verification_revision:, require_citations: true).call
    end

    def initialize(issue:, assessment:, head_sha: nil, verification_revision: nil, require_citations: false)
      @issue = issue
      @assessment = assessment.to_h.deep_stringify_keys
      @head_sha = head_sha
      @verification_revision = verification_revision
      @require_citations = require_citations
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
      issue.present? && Assessment.input_complete?(assessment) && current_revisions? && current_head? && current_verification? && gaps.empty? &&
        criteria.present? && criteria.all? { |criterion| criterion["state"] == "satisfied" && cited?(criterion) }
    end

    def current_revisions?
      assessment["source_revision"] == Assessment.source_revision_for(issue) &&
        assessment["intent_revision"] == Assessment.intent_revision_for(issue)
    end

    def current_head?
      return true unless @head_sha.present?

      assessment["pr_head_sha"] == @head_sha
    end

    def current_verification?
      return true unless @verification_revision.present?

      assessment["verification_revision"] == @verification_revision
    end

    def cited?(criterion)
      return true unless @require_citations

      Array(criterion["evidence"]).any? { |citation| citation.is_a?(Hash) && citation["label"].present? }
    end

    def gaps = Array(assessment["gaps"])

    def criteria
      raw = assessment["criteria"]
      raw.is_a?(Array) && raw.all?(Hash) ? raw : []
    end
  end
end
