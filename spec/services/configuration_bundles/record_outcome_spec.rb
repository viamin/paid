# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::RecordOutcome do
  let(:bundle) { create(:configuration_bundle) }
  let(:agent_run) { create(:agent_run, :completed, :with_metrics, configuration_bundle: bundle) }
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
    expect(outcome.status).to eq("completed")
    expect(outcome.quality_score.to_f).to eq(0.84)
    expect(outcome.cost_cents).to eq(agent_run.cost_cents)
    expect(outcome.duration_seconds).to eq(agent_run.duration_seconds)
    expect(outcome.component_scores).to eq("pr_created" => 1.0)
  end

  it "updates an existing outcome on recollection" do
    described_class.call(agent_run: agent_run, quality_metric: quality_metric)
    quality_metric.update!(composite_score: 0.65, scores: { "pr_created" => 0.0 })

    expect {
      described_class.call(agent_run: agent_run, quality_metric: quality_metric)
    }.not_to change(ConfigurationBundleOutcome, :count)

    expect(agent_run.reload.configuration_bundle_outcome.quality_score.to_f).to eq(0.65)
    expect(agent_run.configuration_bundle_outcome.component_scores).to eq("pr_created" => 0.0)
  end
end
