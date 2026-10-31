# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-PICK-QUEUE-021
RSpec.describe CycleAnalyses::ObviousCorrection do
  def snapshot(effective_edges:)
    { "effective_edges" => effective_edges,
      "issues" => effective_edges.flat_map { |edge| [ edge.fetch("from_issue_id"), edge.fetch("to_issue_id") ] }.uniq.map { |id| { "id" => id } } }
  end

  def edge(id:, from_issue_id: 1, to_issue_id: 2, declaration_source: "issue_body", declaration_url: "https://example.test/1")
    { "id" => id, "from_issue_id" => from_issue_id, "to_issue_id" => to_issue_id,
      "declaration_source" => declaration_source, "declaration_url" => declaration_url }
  end

  def candidate(edge_id:, acyclic: true, missing_or_conflicting_intent: [], evidence: [ "clear evidence" ], action: "remove")
    {
      "declaration_changes" => [ { "edge_id" => edge_id, "action" => action } ],
      "evidence" => evidence,
      "missing_or_conflicting_intent" => missing_or_conflicting_intent,
      "acyclic" => acyclic
    }
  end

  def coverage(unavailable_content_issue_ids: [])
    { "unavailable_content_issue_ids" => unavailable_content_issue_ids }
  end

  def decide(candidates:, edges: [ edge(id: 1) ], coverage_hash: coverage)
    described_class.call(
      recommendation: { "candidates" => candidates },
      coverage: coverage_hash,
      snapshot: snapshot(effective_edges: edges)
    )
  end

  it "qualifies the sole clean, acyclic, fully-provenanced candidate" do
    decision = decide(candidates: [ candidate(edge_id: 1) ])

    expect(decision.candidate).to eq(candidate(edge_id: 1))
    expect(decision.reason).to be_nil
  end

  it "is not obvious when no candidate is acyclic" do
    decision = decide(candidates: [ candidate(edge_id: 1, acyclic: false) ])

    expect(decision.candidate).to be_nil
    expect(decision.reason).to eq("no_qualifying_candidate")
  end

  it "is not obvious when conflicting intent is present, even for a single-edge removal" do
    decision = decide(candidates: [ candidate(edge_id: 1, missing_or_conflicting_intent: [ "Owner disagrees" ]) ])

    expect(decision.candidate).to be_nil
    expect(decision.reason).to eq("no_qualifying_candidate")
  end

  it "qualifies a candidate whose edge has no persisted local provenance" do
    decision = decide(
      candidates: [ candidate(edge_id: 1) ],
      edges: [ edge(id: 1, declaration_source: nil, declaration_url: nil) ]
    )

    expect(decision.candidate).to eq(candidate(edge_id: 1))
    expect(decision.reason).to be_nil
  end

  it "is not obvious when the edge is declared in a comment, outside the write boundary" do
    decision = decide(candidates: [ candidate(edge_id: 1) ], edges: [ edge(id: 1, declaration_source: "issue_comment") ])

    expect(decision.candidate).to be_nil
    expect(decision.reason).to eq("no_qualifying_candidate")
  end

  it "is not obvious when a touched issue's trusted content was unavailable" do
    decision = decide(candidates: [ candidate(edge_id: 1) ], coverage_hash: coverage(unavailable_content_issue_ids: [ 2 ]))

    expect(decision.candidate).to be_nil
    expect(decision.reason).to eq("no_qualifying_candidate")
  end

  it "is ambiguous when more than one candidate qualifies" do
    edges = [ edge(id: 1), edge(id: 2, from_issue_id: 3, to_issue_id: 4) ]
    decision = decide(candidates: [ candidate(edge_id: 1), candidate(edge_id: 2) ], edges:)

    expect(decision.candidate).to be_nil
    expect(decision.reason).to eq("ambiguous_candidates")
  end

  it "requires a correction's replacement to originate from the same declaring issue as its edge" do
    change = { "edge_id" => 1, "action" => "correct", "replacement" => { "from_issue_id" => 99, "to_issue_id" => 2 } }
    candidate_with_bad_correction = candidate(edge_id: 1).merge("declaration_changes" => [ change ])

    decision = decide(candidates: [ candidate_with_bad_correction ])

    expect(decision.candidate).to be_nil
    expect(decision.reason).to eq("no_qualifying_candidate")
  end

  it "does not treat model confidence fields as a substitute for the threshold" do
    confident_but_unevidenced = candidate(edge_id: 1, evidence: []).merge("confidence" => "very high")

    decision = decide(candidates: [ confident_but_unevidenced ])

    expect(decision.candidate).to be_nil
  end

  it "independently rejects a candidate that claims an acyclic result while its declared changes leave a cycle" do
    edges = [ edge(id: 1, from_issue_id: 1, to_issue_id: 2), edge(id: 2, from_issue_id: 2, to_issue_id: 1) ]
    candidate_that_preserves_cycle = candidate(edge_id: 1, acyclic: true).merge(
      "declaration_changes" => [ { "edge_id" => 1, "action" => "correct", "replacement" => { "from_issue_id" => 1, "to_issue_id" => 2 } } ]
    )
    decision = decide(candidates: [ candidate_that_preserves_cycle ], edges:)

    expect(decision.candidate).to be_nil
    expect(decision.reason).to eq("no_qualifying_candidate")
  end
end
