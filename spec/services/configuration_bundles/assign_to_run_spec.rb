# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::AssignToRun do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, issue: create(:issue, project: project)) }
  let(:experiment) do
    create(:configuration_experiment,
      account: project.account,
      status: "running",
      config_key: "knowledge.token_budget",
      control_value: JSON.generate(4000))
  end
  let!(:variant) do
    create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(8000),
      is_control: true)
  end

  it "assigns a deterministic configuration bundle including active experiments" do
    bundle = described_class.call(agent_run: agent_run)

    expect(agent_run.reload.configuration_bundle).to eq(bundle)
    expect(agent_run.configuration_bundle_selection_mode).to eq("exploitative")
    expect(agent_run.configuration_bundle_selection_context).to eq("task")
    expect(bundle.definition).to include(
      "schema_version" => 1,
      "goal" => agent_run.goal,
      "agent_type" => agent_run.agent_type
    )
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to eq(
      "configuration_experiment_id" => experiment.id,
      "configuration_experiment_variant_id" => variant.id,
      "value" => 8000
    )
    expect(ConfigurationExperimentAssignment.find_by(configuration_experiment: experiment, agent_run: agent_run)).to be_present
  end

  it "reuses the same bundle for identical run configurations" do
    first_run = create(:agent_run, project: project, issue: create(:issue, project: project))
    second_run = create(:agent_run,
      project: project,
      issue: create(:issue, project: project),
      agent_type: first_run.agent_type,
      goal: first_run.goal,
      provider: first_run.provider,
      prompt_version: first_run.prompt_version,
      custom_prompt: first_run.custom_prompt)

    first_bundle = described_class.call(agent_run: first_run)
    second_bundle = described_class.call(agent_run: second_run)

    expect(second_bundle).to eq(first_bundle)
    expect(ConfigurationBundle.count).to eq(1)
  end

  it "falls back to direct experiment assignment when optimization fails" do
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_raise(StandardError, "optimizer unavailable")

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle).to be_persisted
    expect(agent_run.reload.configuration_bundle).to eq(bundle)
    expect(agent_run.configuration_bundle_selection_mode).to be_nil
    expect(agent_run.configuration_bundle_selection_context).to be_nil
    expect(ConfigurationExperimentAssignment.find_by(configuration_experiment: experiment, agent_run: agent_run)).to be_present
  end

  it "skips malformed experiment values instead of aborting assignment" do
    variant.update!(config_value: "{not-json")

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle).to be_persisted
    expect(agent_run.reload.configuration_bundle).to eq(bundle)
    expect(bundle.definition.fetch("experiments")).to eq({})
    expect(ConfigurationExperimentAssignment.find_by(configuration_experiment: experiment, agent_run: agent_run)).to be_nil
  end

  it "records exploratory routing metadata when the optimizer selects an exploratory bundle" do
    selection = ConfigurationBundles::Optimizer::Selection.new(
      variant_by_experiment_id: { experiment.id => variant },
      selection_mode: "exploratory",
      selection_context: "task"
    )
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    described_class.call(agent_run: agent_run)

    expect(agent_run.reload.configuration_bundle_selection_mode).to eq("exploratory")
    expect(agent_run.configuration_bundle_selection_context).to eq("task")
  end
end
