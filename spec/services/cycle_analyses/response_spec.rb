# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Response do
  let(:snapshot) do
    {
      "issues" => [ { "id" => 10 }, { "id" => 20 }, { "id" => 30 } ],
      "effective_edges" => [
        { "id" => 101, "from_issue_id" => 10, "to_issue_id" => 20 },
        { "id" => 102, "from_issue_id" => 20, "to_issue_id" => 10 },
        { "id" => 103, "from_issue_id" => 20, "to_issue_id" => 30 },
        { "id" => 104, "from_issue_id" => 30, "to_issue_id" => 20 }
      ]
    }
  end

  def recommendation(changes: [ { "edge_id" => 101, "action" => "remove" } ],
    issue_ids: [ 10, 20, 30 ], edges: expected_edges_without(101), acyclic: false)
    {
      "summary" => "Review the complete cycle.",
      "candidates" => [ {
        "declaration_changes" => changes,
        "evidence" => [ "The declaration is obsolete." ],
        "tradeoffs" => [ "Work ordering changes." ],
        "missing_or_conflicting_intent" => [],
        "resulting_graph" => { "issue_ids" => issue_ids, "edges" => edges },
        "acyclic" => acyclic
      } ]
    }
  end

  def expected_edges_without(*edge_ids)
    snapshot.fetch("effective_edges").reject { |edge| edge_ids.include?(edge.fetch("id")) }
      .map { |edge| edge.slice("from_issue_id", "to_issue_id") }
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects declaration changes for edges outside the snapshot" do
    changes = [ { "edge_id" => 999, "action" => "remove" } ]

    expect { described_class.parse(recommendation(changes:).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /edge_id is not in the snapshotted cycle/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects resulting graph nodes outside the snapshot" do
    expect { described_class.parse(recommendation(issue_ids: [ 10, 20, 999 ]).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /issue_ids must match the snapshotted cycle/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects resulting graph edges with nodes outside the snapshot" do
    edges = [ { "from_issue_id" => 10, "to_issue_id" => 999 } ]

    expect { described_class.parse(recommendation(edges:).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /to_issue_id is not in the resulting graph/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects an acyclic claim when the resulting graph contains a cycle" do
    expect { described_class.parse(recommendation(acyclic: true).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /acyclic does not match the resulting graph/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "accepts a cyclic claim when the resulting graph contains a cycle" do
    result = described_class.parse(recommendation.to_json, snapshot:)

    expect(result.dig("candidates", 0, "acyclic")).to be(false)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects a resulting graph that silently removes unchanged snapshot edges" do
    expect { described_class.parse(recommendation(edges: []).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /edges must match the snapshotted cycle after applying declaration_changes/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects a resulting graph that adds an undeclared edge" do
    edges = expected_edges_without(101) + [ { "from_issue_id" => 10, "to_issue_id" => 30 } ]

    expect { described_class.parse(recommendation(edges:).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /edges must match the snapshotted cycle after applying declaration_changes/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects multiple declaration changes for the same snapshot edge" do
    changes = [
      { "edge_id" => 101, "action" => "remove" },
      { "edge_id" => 101, "action" => "remove" }
    ]

    expect { described_class.parse(recommendation(changes:).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /edge_id must be unique/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "accepts an explicit endpoint correction reflected in the resulting graph" do
    replacement = { "from_issue_id" => 10, "to_issue_id" => 30 }
    changes = [ { "edge_id" => 101, "action" => "correct", "replacement" => replacement } ]
    edges = expected_edges_without(101) + [ replacement ]

    result = described_class.parse(recommendation(changes:, edges:, acyclic: false).to_json, snapshot:)

    expect(result.dig("candidates", 0, "resulting_graph", "edges")).to match_array(edges)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects a correction without replacement endpoints" do
    changes = [ { "edge_id" => 101, "action" => "correct" } ]

    expect { described_class.parse(recommendation(changes:).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /replacement must be an object/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "accepts an acyclic graph produced by multiple declared removals" do
    changes = [
      { "edge_id" => 101, "action" => "remove" },
      { "edge_id" => 103, "action" => "remove" }
    ]
    edges = expected_edges_without(101, 103)

    result = described_class.parse(recommendation(changes:, edges:, acyclic: true).to_json, snapshot:)

    expect(result.dig("candidates", 0, "acyclic")).to be(true)
  end
end
