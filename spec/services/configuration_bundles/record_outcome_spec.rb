# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::RecordOutcome do
  let(:project) { create(:project) }
  let(:bundle) { create(:configuration_bundle, account: project.account) }
  let(:agent_run) do
    create(:agent_run,
      :completed,
      :with_metrics,
      project: project,
      issue: create(:issue, project: project),
      configuration_bundle: bundle)
  end
  let(:quality_metric) do
    create(:quality_metric,
      agent_run: agent_run,
      metric_type: "automated",
      composite_score: 0.84,
      scores: { "pr_created" => 1.0 })
  end

  it "persists the optimization outcome for the run bundle" do
    outcome = described_class.call(agent_run: agent_run, quality_metric: quality_metric)

    expect(outcome).to be_persisted
    expect(outcome.configuration_bundle).to eq(bundle)
    expect(outcome.agent_run).to eq(agent_run)
    expect(outcome.success).to be(true)
    expect(outcome.quality_score.to_f).to eq(0.84)
    expect(outcome.cost_cents).to eq(agent_run.cost_cents)
    expect(outcome.duration_seconds).to eq(agent_run.duration_seconds)
    expect(outcome.tokens_used).to eq(agent_run.tokens_input + agent_run.tokens_output)
    expect_metric_summary(outcome)
    expect_metric_timestamps(outcome)
  end

  it "updates an existing outcome on recollection" do
    described_class.call(agent_run: agent_run, quality_metric: quality_metric)
    quality_metric.update!(composite_score: 0.65, scores: { "pr_created" => 0.0 })

    expect {
      described_class.call(agent_run: agent_run, quality_metric: quality_metric)
    }.not_to change(BundleOutcome, :count)

    expect(agent_run.reload.bundle_outcomes.sole.quality_score.to_f).to eq(0.65)
    expect(agent_run.bundle_outcomes.sole.metrics.fetch("component_scores")).to eq("pr_created" => 0.0)
  end

  def expect_metric_summary(outcome)
    expect(outcome.metrics).to include(
      "component_scores" => { "pr_created" => 1.0 },
      "execution_duration_seconds" => agent_run.duration_seconds,
      "objective_score" => be_within(0.001).of(0.684),
      "outcome" => "completed",
      "quality_per_dollar" => be_within(0.001).of(0.56),
      "queue_duration_seconds" => be_a(Integer),
      "status" => "completed",
      "success" => true,
      "tokens_input" => agent_run.tokens_input,
      "tokens_output" => agent_run.tokens_output,
      "total_duration_seconds" => be_a(Integer)
    )
  end

  def expect_metric_timestamps(outcome)
    expect(outcome.metrics.fetch("created_at")).to eq(agent_run.created_at.iso8601)
    expect(outcome.metrics.fetch("started_at")).to eq(agent_run.started_at.iso8601)
    expect(outcome.metrics.fetch("completed_at")).to eq(agent_run.completed_at.iso8601)
  end
end
