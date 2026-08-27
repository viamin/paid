# frozen_string_literal: true

require "rails_helper"

RSpec.describe PageLoadPerformance::EvaluateRegressions do
  let(:project) { create(:project, screenshot_settings: { "enabled" => true }) }
  let(:agent_run) do
    create(:agent_run,
      project: project,
      branch_name: "paid/perf",
      pull_request_number: 42,
      result_commit_sha: "bbb2222")
  end
  let(:hints) { { "dashboard" => { "summary" => "changed the dashboard" } } }

  def baseline(**overrides)
    create(:page_load_measurement,
      project: project,
      pull_request_number: 42,
      commit_sha: "aaa1111",
      captured_at: 1.hour.ago,
      **overrides)
  end

  def current(**overrides)
    create(:page_load_measurement,
      project: project,
      agent_run: agent_run,
      pull_request_number: 42,
      commit_sha: "bbb2222",
      **overrides)
  end

  def stub_open_finding_race(measurement:, existing:)
    duplicate = build(:page_load_regression_finding,
      project: project,
      agent_run: agent_run,
      pull_request_number: 42,
      route_name: measurement.route_name,
      status: "open")
    conflict = ActiveRecord::RecordNotUnique.new(
      "PG::UniqueViolation: #{PageLoadPerformance::EvaluateRegressions::OPEN_FINDING_UNIQUE_CONSTRAINT}"
    )
    first_scope = instance_double(ActiveRecord::Relation, first_or_initialize: duplicate)
    second_scope = instance_double(ActiveRecord::Relation, sole: existing)

    allow(duplicate).to receive(:save!).and_raise(conflict)
    allow(PageLoadRegressionFinding).to receive(:where).and_call_original
    allow(PageLoadRegressionFinding).to receive(:where).with(
      project_id: project.id,
      pull_request_number: measurement.pull_request_number,
      route_name: measurement.route_name,
      status: "open"
    ).and_return(first_scope, second_scope)
  end

  def create_existing_open_finding(measurement)
    create(:page_load_regression_finding,
      project: project,
      agent_run: agent_run,
      pull_request_number: 42,
      route_name: measurement.route_name,
      comparison_metric: "lcp_ms",
      baseline_ms: 600,
      current_ms: 900,
      delta_ms: 300,
      delta_ratio: 0.5,
      baseline_commit_sha: "older111",
      commit_sha: "older222",
      route_path: measurement.route_path,
      actionable: false)
  end

  def expect_open_finding_refresh(existing)
    expect(existing.reload).to have_attributes(
      baseline_ms: 640,
      current_ms: 1_100,
      commit_sha: "bbb2222",
      actionable: true,
      status: "open"
    )
    expect(PageLoadRegressionFinding.count).to eq(1)
  end

  # @spec PAGE-LOAD-REGRESSION-001, PAGE-LOAD-REGRESSION-002
  it "flags a route that exceeds both the ratio and the absolute floor" do
    baseline(lcp_ms: 640)
    measurement = current(lcp_ms: 1100)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first).to have_attributes(
      route_name: "dashboard",
      status: "regressed",
      metric: "lcp_ms",
      baseline_ms: 640,
      current_ms: 1100,
      delta_ms: 460
    )
  end

  # @spec PAGE-LOAD-REGRESSION-002
  it "does not flag a proportionally large slowdown below the absolute floor" do
    baseline(lcp_ms: 40)
    measurement = current(lcp_ms: 90)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first.status).to eq("unchanged")
    expect(PageLoadRegressionFinding.count).to eq(0)
  end

  # @spec PAGE-LOAD-REGRESSION-002
  it "does not flag a large absolute slowdown below the ratio" do
    baseline(lcp_ms: 5_000)
    measurement = current(lcp_ms: 5_800)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first.status).to eq("unchanged")
  end

  # @spec PAGE-LOAD-REGRESSION-001
  it "falls back to the load metric when the configured metric is null on either side" do
    baseline(lcp_ms: nil, load_ms: 800)
    measurement = current(lcp_ms: nil, load_ms: 1_600)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first).to have_attributes(status: "regressed", metric: "load_ms")
  end

  # @spec PAGE-LOAD-REGRESSION-003
  it "reports no baseline when the route has no earlier measurement on the pull request" do
    measurement = current(lcp_ms: 1_100)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first.status).to eq("no_baseline")
    expect(PageLoadRegressionFinding.count).to eq(0)
  end

  # @spec PAGE-LOAD-REGRESSION-004
  it "reports not comparable when the route resolved to a different path" do
    baseline(route_path: "/dashboard", lcp_ms: 640)
    measurement = current(route_path: "/overview", lcp_ms: 1_100)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first.status).to eq("not_comparable")
    expect(PageLoadRegressionFinding.count).to eq(0)
  end

  # @spec PAGE-LOAD-REGRESSION-004
  it "reports not comparable when the responses differ in HTTP status" do
    baseline(http_status: 200, lcp_ms: 640)
    measurement = current(http_status: 500, lcp_ms: 1_100)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first.status).to eq("not_comparable")
  end

  # @spec PAGE-LOAD-REGRESSION-004
  it "reports not comparable when the viewport differs" do
    baseline(viewport_width: 1280, lcp_ms: 640)
    measurement = current(viewport_width: 375, lcp_ms: 1_100)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first.status).to eq("not_comparable")
  end

  # @spec PAGE-LOAD-REGRESSION-005
  it "persists an actionable finding carrying the comparison evidence" do
    baseline(lcp_ms: 640)
    measurement = current(lcp_ms: 1_100)

    described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    finding = PageLoadRegressionFinding.sole
    expect(finding).to have_attributes(
      project_id: project.id,
      pull_request_number: 42,
      route_name: "dashboard",
      comparison_metric: "lcp_ms",
      baseline_ms: 640,
      current_ms: 1_100,
      baseline_commit_sha: "aaa1111",
      commit_sha: "bbb2222",
      actionable: true,
      status: "open"
    )
  end

  # @spec PAGE-LOAD-FOLLOWUP-003
  it "marks a finding for an untouched route as not actionable" do
    baseline(lcp_ms: 640)
    measurement = current(lcp_ms: 1_100)

    described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: {})

    expect(PageLoadRegressionFinding.sole.actionable).to be false
  end

  # @spec PAGE-LOAD-REGRESSION-009
  it "updates the open finding instead of opening a second one for the route" do
    baseline(lcp_ms: 640)
    described_class.call(agent_run: agent_run, measurements: [ current(lcp_ms: 1_100) ], hints: hints)

    later_run = create(:agent_run, project: project, pull_request_number: 42, result_commit_sha: "ccc3333")
    later = create(:page_load_measurement,
      project: project, agent_run: later_run, pull_request_number: 42,
      commit_sha: "ccc3333", lcp_ms: 1_400)
    described_class.call(agent_run: later_run, measurements: [ later ], hints: hints)

    expect(PageLoadRegressionFinding.count).to eq(1)
    expect(PageLoadRegressionFinding.sole).to have_attributes(current_ms: 1_400, commit_sha: "ccc3333", status: "open")
  end

  # @spec PAGE-LOAD-REGRESSION-009
  it "self-heals an open-finding unique race by updating the existing row" do
    baseline(lcp_ms: 640)
    measurement = current(lcp_ms: 1_100)
    existing = create_existing_open_finding(measurement)
    stub_open_finding_race(measurement:, existing:)

    comparisons = described_class.call(agent_run: agent_run, measurements: [ measurement ], hints: hints)

    expect(comparisons.first.finding.id).to eq(existing.id)
    expect_open_finding_refresh(existing)
  end

  # @spec PAGE-LOAD-REGRESSION-006
  it "resolves the open finding when a later capture is back within threshold" do
    baseline(lcp_ms: 640)
    described_class.call(agent_run: agent_run, measurements: [ current(lcp_ms: 1_100) ], hints: hints)

    later_run = create(:agent_run, project: project, pull_request_number: 42, result_commit_sha: "ccc3333")
    later = create(:page_load_measurement,
      project: project, agent_run: later_run, pull_request_number: 42,
      commit_sha: "ccc3333", lcp_ms: 660)
    described_class.call(agent_run: later_run, measurements: [ later ], hints: hints)

    finding = PageLoadRegressionFinding.sole
    expect(finding.status).to eq("resolved")
    expect(finding.resolved_at).to be_present
  end

  # @spec PAGE-LOAD-REGRESSION-008
  it "supersedes an open finding for a route a later capture no longer measures" do
    baseline(lcp_ms: 640)
    described_class.call(agent_run: agent_run, measurements: [ current(lcp_ms: 1_100) ], hints: hints)

    later_run = create(:agent_run, project: project, pull_request_number: 42, result_commit_sha: "ccc3333")
    other = create(:page_load_measurement,
      project: project, agent_run: later_run, pull_request_number: 42,
      commit_sha: "ccc3333", route_name: "settings", route_path: "/settings")
    described_class.call(agent_run: later_run, measurements: [ other ], hints: { "settings" => {} })

    expect(PageLoadRegressionFinding.find_by(route_name: "dashboard").status).to eq("superseded")
  end

  # @spec PAGE-LOAD-CONFIG-001
  it "honors project-configured thresholds" do
    project.update!(screenshot_settings: project.screenshot_settings.merge(
      "performance" => { "regression_ratio" => 0.05, "regression_floor_ms" => 10 }
    ))
    baseline(lcp_ms: 640)
    measurement = current(lcp_ms: 700)

    comparisons = described_class.call(agent_run: agent_run.reload, measurements: [ measurement ], hints: hints)

    expect(comparisons.first.status).to eq("regressed")
  end
end
