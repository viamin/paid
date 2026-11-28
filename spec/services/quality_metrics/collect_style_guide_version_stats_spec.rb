# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::Collect do # @spec QUALITY-LOOPS-010
  let(:run) { create(:agent_run, :completed, iterations: 3) }
  let(:collector) { described_class.new(agent_run: run) }

  def expose(guide, agent_run: run)
    create(:style_guide_run_exposure, agent_run: agent_run, style_guide: guide,
      style_guide_version: guide.current_version, guide_name: guide.name)
  end

  def guide
    create(:style_guide, account: run.project.account, project: nil)
  end

  it "uses one aggregate for multiple exposed versions and preserves their independent scores" do
    first = guide
    second = guide
    expose(first)
    expose(second)
    create(:quality_metric, agent_run: run, metric_type: "automated", composite_score: 0.765432)

    other_run = create(:agent_run, :completed, project: run.project, iterations: 3)
    expose(first, agent_run: other_run)
    create(:quality_metric, agent_run: other_run, metric_type: "automated", composite_score: 0.2)
    create(:quality_metric, :human, agent_run: run, composite_score: 1.0)
    excluded_run = create(:agent_run, project: run.project, status: "auth_expired", iterations: 3)
    expose(second, agent_run: excluded_run)
    create(:quality_metric, agent_run: excluded_run, metric_type: "automated", composite_score: 0.01)

    queries = capture_queries { collector.send(:update_style_guide_version_stats) }
    aggregates = queries.grep(/COUNT\(DISTINCT style_guide_run_exposures.agent_run_id\)/)

    expect(aggregates.size).to eq(1)
    expect(first.current_version.reload.usage_count).to eq(2)
    expect(first.current_version.avg_quality_score).to eq(0.4827)
    expect(second.current_version.reload.usage_count).to eq(1)
    expect(second.current_version.avg_quality_score).to eq(0.7654)
  end

  it "resets empty exposed groups without updating unexposed versions" do
    exposed = guide
    unexposed = guide
    [ exposed, unexposed ].each { |item| item.current_version.update_columns(usage_count: 9, avg_quality_score: 0.8) }
    expose(exposed)
    create(:quality_metric, agent_run: run, metric_type: "automated", composite_score: nil)

    collector.send(:update_style_guide_version_stats)

    expect(exposed.current_version.reload.usage_count).to eq(0)
    expect(exposed.current_version.avg_quality_score).to be_nil
    expect(unexposed.current_version.reload.usage_count).to eq(9)
    expect(unexposed.current_version.avg_quality_score).to eq(0.8)
  end
end
