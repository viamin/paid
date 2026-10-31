# frozen_string_literal: true

module CycleAnalyses
  # Applies the AUTO-PICK-QUEUE-021 obvious-correction threshold to an
  # already-validated cycle-analysis recommendation. Pure evaluation over the
  # snapshotted evidence — the pre-write safety checks against freshly
  # fetched data live in ApplyRepair.
  class ObviousCorrection
    Decision = Data.define(:candidate, :reason)

    WRITABLE_SOURCE = "issue_body"

    def self.call(...) = new(...).call

    def initialize(recommendation:, coverage:, snapshot:)
      @recommendation = recommendation
      @coverage = coverage
      @snapshot = snapshot
    end

    # @spec AUTO-PICK-QUEUE-021
    def call
      qualifying = candidates.select { |candidate| qualifies?(candidate) }
      return Decision.new(candidate: nil, reason: "no_qualifying_candidate") if qualifying.empty?
      return Decision.new(candidate: nil, reason: "ambiguous_candidates") if qualifying.size > 1

      Decision.new(candidate: qualifying.first, reason: nil)
    end

    private

    attr_reader :recommendation, :coverage, :snapshot

    def candidates = recommendation.fetch("candidates")

    def qualifies?(candidate)
      candidate["acyclic"] == true &&
        Array(candidate["missing_or_conflicting_intent"]).empty? &&
        Array(candidate["evidence"]).any? &&
        writable?(candidate) &&
        content_available?(candidate) &&
        corrections_preserve_declaring_issue?(candidate) &&
        resulting_graph_acyclic?(candidate)
    end

    # Missing *local* provenance alone never disqualifies: plenty of
    # pre-existing edges predate provenance tracking even though the live
    # GitHub declaration they describe is current. ApplyRepair resolves that
    # case with a live lookup before writing. A known non-body source (a
    # comment, outside the existing write boundary) does disqualify.
    def writable?(candidate)
      edge_changes(candidate).all? do |change|
        edge = edges_by_id[change.fetch("edge_id")]
        edge && writable_source?(edge["declaration_source"])
      end
    end

    def writable_source?(source) = source.nil? || source == WRITABLE_SOURCE

    def content_available?(candidate)
      unavailable = Set.new(coverage.fetch("unavailable_content_issue_ids", []))
      touched_issue_ids(candidate).none? { |id| unavailable.include?(id) }
    end

    def corrections_preserve_declaring_issue?(candidate)
      edge_changes(candidate).all? do |change|
        next true unless change.fetch("action") == "correct"

        edge = edges_by_id[change.fetch("edge_id")]
        edge && change.fetch("replacement").fetch("from_issue_id") == edge["from_issue_id"]
      end
    end

    # The response parser also checks this for agent-produced payloads, but
    # keep the safety threshold self-contained: a caller must never be able
    # to turn a model assertion into write authority merely by setting
    # `acyclic: true`.
    def resulting_graph_acyclic?(candidate)
      changes_by_edge_id = edge_changes(candidate).index_by { |change| change.fetch("edge_id") }
      edges = snapshot.fetch("effective_edges").filter_map do |edge|
        change = changes_by_edge_id[edge.fetch("id")]
        next edge.slice("from_issue_id", "to_issue_id") unless change
        next if change.fetch("action") == "remove"

        change.fetch("replacement")
      end
      AcyclicGraph.call(issue_ids: snapshot.fetch("issues", []).pluck("id"), edges:)
    end

    def touched_issue_ids(candidate)
      edge_changes(candidate).flat_map do |change|
        edge = edges_by_id[change.fetch("edge_id")]
        edge ? [ edge["from_issue_id"], edge["to_issue_id"] ] : []
      end
    end

    def edge_changes(candidate) = candidate.fetch("declaration_changes")

    def edges_by_id
      @edges_by_id ||= snapshot.fetch("effective_edges").index_by { |edge| edge.fetch("id") }
    end
  end
end
