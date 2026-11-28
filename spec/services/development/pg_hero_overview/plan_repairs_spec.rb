# frozen_string_literal: true

require "rails_helper"

RSpec.describe Development::PgHeroOverview::PlanRepairs do
  let(:project) { create(:project) }
  let(:first) { finding("suggested_index/issues/project_id", { table: "issues", columns: [ "project_id" ] }) }
  let(:second) { finding("suggested_index/issues/project_id,status", { table: "issues", columns: %w[project_id status] }) }
  let(:findings) { [ first, second ] }
  let(:work_items) { [] }
  let(:planner) { described_class.new(project: project, findings: findings, work_items: work_items, existing_repairs: []) }
  let(:proposal) do
    { "title" => "Cover issue project and status access", "instructions" => "Verify and add one compound index",
      "rationale" => "Both query plans can use this index", "finding_keys" => findings.map(&:identity),
      "owner_issue_number" => nil, "owner_pr_number" => nil, "publication_ready" => true,
      "evidence" => "Both measured plans use the retained leading-column prefix", "missing_evidence" => [] }
  end
  let(:payload) { { "repairs" => [ proposal ], "deferred" => [] } }

  def finding(key, observed)
    Development::PgHeroOverview::Finding.new(type: :suggested_index, key: key, title: key,
      observed: observed, observed_at: Time.current, database: "primary", category: :suggested_indexes,
      persistence_required: false)
  end

  before do
    allow(Llm::Request).to receive(:call) { Struct.new(:output).new(JSON.generate(payload)) }
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "assesses two missing-index findings as one repair through the harness boundary" do
    result = planner.call

    expect(result.fetch("repairs").size).to eq(1)
    expect(result.fetch("repairs").first.fetch("finding_keys")).to match_array(findings.map(&:identity))
    expect(Llm::Request).to have_received(:call).with(hash_including(project: project, timeout: 120))
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "reuses an existing PR without requiring a new issue" do
    work_items << { "number" => 42, "kind" => "pull_request", "title" => "Cover issue queries", "body" => "Existing repair" }
    proposal["owner_pr_number"] = 42

    expect(planner.call.fetch("repairs").first.fetch("owner_pr_number")).to eq(42)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "keeps independent repairs separate even on the same table" do
    payload["repairs"] = findings.map do |f|
      proposal.merge("finding_keys" => [ f.identity ], "instructions" => "Distinct repair for #{f.key}")
    end

    expect(planner.call.fetch("repairs").size).to eq(2)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "retains reasoned deferrals instead of inventing work" do
    payload["repairs"] = []
    payload["deferred"] = [ { "finding_keys" => findings.map(&:identity), "reason" => "Need query plans" } ]

    expect(planner.call.fetch("deferred").first.fetch("reason")).to eq("Need query plans")
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "rejects unknown or foreign-project owners" do
    proposal["owner_issue_number"] = 999

    expect { planner.call }.to raise_error(described_class::InvalidAssessment)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "rejects omitted or multiply-owned findings" do
    proposal["finding_keys"] = [ first.identity ]
    expect { planner.call }.to raise_error(described_class::InvalidAssessment)
    proposal["finding_keys"] = [ first.identity, first.identity, second.identity ]
    expect { planner.call }.to raise_error(described_class::InvalidAssessment)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "rejects unknown keys and cross-database repair proposals" do
    proposal["finding_keys"] << "other/suggested_index/foreign"

    expect { planner.call }.to raise_error(described_class::InvalidAssessment)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "fails closed on malformed or unavailable assessment" do
    allow(Llm::Request).to receive(:call).and_return(Struct.new(:output).new("invalid JSON"))
    expect { planner.call }.to raise_error(described_class::InvalidAssessment)
    allow(Llm::Request).to receive(:call).and_raise(AgentHarness::TimeoutError, "timed out")
    expect { planner.call }.to raise_error(AgentHarness::TimeoutError)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "bounds input and never silently discards existing work" do
    work_items.concat(Array.new(2_001) { { "number" => 1, "kind" => "issue" } })

    expect { planner.call }.to raise_error(described_class::InvalidAssessment)
    expect(Llm::Request).not_to have_received(:call)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "validates the harness response object before accepting a candidate" do
    allow(Llm::Request).to receive(:call) do |**arguments|
      response = Struct.new(:output).new(JSON.generate(payload))
      expect(arguments.fetch(:response_validator).call(response)).to be(true)
      response
    end
    expect(planner.call.fetch("repairs").size).to eq(1)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "selects relevant evidence from the full work index when bodies exceed the input budget" do
    work_items.concat((1..300).map do |number|
      { "number" => number, "kind" => "issue", "title" => "Repair #{number}", "body" => "x" * 3_000 }
    end)
    proposal["owner_issue_number"] = 42
    allow(Llm::Request).to receive(:call) do |**arguments|
      selection = arguments.fetch(:timeout) == 90
      output = selection ? { "work_numbers" => [ 42 ], "finding_keys" => findings.map(&:identity), "reason" => "Assess this repair scope first" } : payload
      response = Struct.new(:output).new(JSON.generate(output))
      expect(arguments.fetch(:response_validator).call(response)).to be(true)
      expect(arguments.fetch(:prompt).bytesize).to be < 100_000
      expect(arguments.fetch(:prompt)).to include('Repair 300') if selection
      response
    end

    expect(planner.call.fetch("repairs").first.fetch("owner_issue_number")).to eq(42)
  end

  # @spec RAILS-CONTROL-PLANE-033
  it "retains unselected observations as reasoned deferrals while assessing selected repairs" do
    work_items.concat((1..100).map { |number| { "number" => number, "kind" => "issue", "title" => "Repair", "body" => "x" * 3_000 } })
    proposal["finding_keys"] = [ first.identity ]
    allow(Llm::Request).to receive(:call) do |**arguments|
      output = if arguments.fetch(:timeout) == 90
        { "finding_keys" => [ first.identity ], "work_numbers" => [], "reason" => "Assess the remaining scope next scan" }
      else
        payload
      end
      Struct.new(:output).new(JSON.generate(output))
    end

    result = planner.call

    expect(result.fetch("repairs").first.fetch("finding_keys")).to eq([ first.identity ])
    expect(result.fetch("deferred")).to include(hash_including("finding_keys" => [ second.identity ],
      "reason" => "Assess the remaining scope next scan"))
  end

  # @spec RAILS-CONTROL-PLANE-037
  it "defers a conditional proposal instead of publishing it" do
    proposal["publication_ready"] = false
    proposal["missing_evidence"] = [ "Representative workload and query plans" ]

    result = planner.call

    expect(result.fetch("repairs")).to be_empty
    expect(result.fetch("deferred")).to include(hash_including("finding_keys" => findings.map(&:identity),
      "reason" => include("Representative workload and query plans")))
  end

  # @spec RAILS-CONTROL-PLANE-037
  it "rejects affirmative readiness that still declares missing evidence" do
    proposal["missing_evidence"] = [ "Need a query plan" ]

    expect { planner.call }.to raise_error(described_class::InvalidAssessment)
  end

  # @spec RAILS-CONTROL-PLANE-036
  it "does not count the unselected scope as a detailed assessment" do
    work_items.concat((1..100).map { |number| { "number" => number, "kind" => "issue", "title" => "Repair", "body" => "x" * 3_000 } })
    proposal["finding_keys"] = [ first.identity ]
    allow(Llm::Request).to receive(:call) do |**arguments|
      result = arguments.fetch(:timeout) == 90 ?
        { "finding_keys" => [ first.identity ], "work_numbers" => [], "reason" => "Next scope later" } : payload
      Struct.new(:output).new(JSON.generate(result))
    end

    expect(planner.call.fetch("assessed_finding_keys")).to eq([ first.identity ])
  end

  # @spec RAILS-CONTROL-PLANE-036
  it "rejects selection that repeatedly skips the least recently assessed finding" do
    work_items.concat((1..100).map { |number| { "number" => number, "kind" => "issue", "title" => "Repair", "body" => "x" * 3_000 } })
    planner = described_class.new(project: project, findings: findings, work_items: work_items, existing_repairs: [],
      assessments: { first.identity => { "assessed_at" => Time.current.utc.iso8601 } })
    allow(Llm::Request).to receive(:call).and_return(Struct.new(:output).new(JSON.generate(
      { "finding_keys" => [ first.identity ], "work_numbers" => [], "reason" => "Same scope again" })))

    expect { planner.call }.to raise_error(described_class::InvalidAssessment)
  end
end
