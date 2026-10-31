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

  def recommendation(edge_id: 101, issue_ids: [ 10, 20, 30 ], edges: [], acyclic: true)
    {
      "summary" => "Review the complete cycle.",
      "candidates" => [ {
        "declaration_changes" => [ { "edge_id" => edge_id, "action" => "remove" } ],
        "evidence" => [ "The declaration is obsolete." ],
        "tradeoffs" => [ "Work ordering changes." ],
        "missing_or_conflicting_intent" => [],
        "resulting_graph" => { "issue_ids" => issue_ids, "edges" => edges },
        "acyclic" => acyclic
      } ]
    }
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects declaration changes for edges outside the snapshot" do
    expect { described_class.parse(recommendation(edge_id: 999).to_json, snapshot:) }
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
    edges = [
      { "from_issue_id" => 10, "to_issue_id" => 20 },
      { "from_issue_id" => 20, "to_issue_id" => 10 }
    ]

    expect { described_class.parse(recommendation(edges:, acyclic: true).to_json, snapshot:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /acyclic does not match the resulting graph/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "accepts a cyclic claim when the resulting graph contains a cycle" do
    edges = [
      { "from_issue_id" => 10, "to_issue_id" => 20 },
      { "from_issue_id" => 20, "to_issue_id" => 10 }
    ]

    result = described_class.parse(recommendation(edges:, acyclic: false).to_json, snapshot:)

    expect(result.dig("candidates", 0, "acyclic")).to be(false)
  end
end
