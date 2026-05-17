# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::AssignToRun do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run,
      project: project,
      issue: create(:issue, project: project),
      mcp_server_snapshot: [ filesystem_mcp_snapshot ])
  end
  let(:llm_model) { create(:llm_model, provider: "openai", model_id: "gpt-5.4") }
  let(:first_service) { create(:service_container, account: project.account) }
  let(:second_service) { create(:service_container, :redis, account: project.account) }
  let(:expected_model_selection) do
    {
      "escalated_from_tier" => "mid",
      "escalated_reason" => "quality_recovery_project",
      "llm_model_id" => "gpt-5.4",
      "llm_provider" => "openai",
      "selector_type" => "quality_escalation",
      "tier" => "high"
    }
  end
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
  let(:model_selection) do
    create(:model_selection,
      agent_run: agent_run,
      llm_model: llm_model,
      selector_type: "quality_escalation",
      tier: "high",
      escalated_from_tier: "mid",
      escalated_reason: "quality_recovery_project")
  end
  let(:project_services) do
    [
      create(:project_service_container, project: project, service_container: second_service),
      create(:project_service_container, project: project, service_container: first_service)
    ]
  end

  it "assigns a deterministic configuration bundle and records project context during task bootstrap" do
    model_selection
    project_services

    bundle = described_class.call(agent_run: agent_run)

    expect(agent_run.reload.configuration_bundle).to eq(bundle)
    expect(agent_run.configuration_bundle_selection_mode).to eq("exploitative")
    expect(agent_run.configuration_bundle_selection_context).to eq("project")
    expect_bundle_definition(bundle)
    expect_bundle_identity(bundle)
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

  it "creates different bundles for different selected models under the same provider" do
    first_run = create(:agent_run, project: project, issue: create(:issue, project: project))
    second_run = create(:agent_run,
      project: project,
      issue: create(:issue, project: project),
      agent_type: first_run.agent_type,
      goal: first_run.goal,
      provider: first_run.provider,
      prompt_version: first_run.prompt_version,
      custom_prompt: first_run.custom_prompt)

    create(:model_selection, agent_run: first_run, llm_model: create(:llm_model, provider: "openai", model_id: "gpt-5.4-mini"))
    create(:model_selection, agent_run: second_run, llm_model: create(:llm_model, provider: "openai", model_id: "gpt-5.4"))

    first_bundle = described_class.call(agent_run: first_run)
    second_bundle = described_class.call(agent_run: second_run)

    expect(second_bundle).not_to eq(first_bundle)
    expect(ConfigurationBundle.count).to eq(2)
  end

  it "creates different bundles when MCP snapshots differ behind the same name" do
    first_run = create(:agent_run,
      project: project,
      issue: create(:issue, project: project),
      mcp_server_snapshot: [ { "name" => "filesystem", "command" => "npx" } ])
    second_run = create(:agent_run,
      project: project,
      issue: create(:issue, project: project),
      mcp_server_snapshot: [ { "name" => "filesystem", "command" => "uvx" } ])

    first_bundle = described_class.call(agent_run: first_run)
    second_bundle = described_class.call(agent_run: second_run)

    expect(second_bundle).not_to eq(first_bundle)
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

  it "uses the optimizer-provided bundle definition when available" do
    optimized_definition = optimizer_definition_with_value(12_000)
    selection = optimizer_selection(definition: optimized_definition)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.definition).to eq(optimized_definition)
    expect(bundle.fingerprint).to eq(selection.fingerprint)
    expect_bundle_identity(bundle)
  end

  it "accepts optimizer definitions that include marketplace attachments" do
    attachment = create(:agent_run_marketplace_entry, agent_run: agent_run)
    optimized_definition = optimizer_definition_with_value(12_000).merge(
      "marketplace_entries" => [
        {
          "entry_id" => attachment.marketplace_entry_id,
          "version_id" => attachment.marketplace_entry_version_id,
          "source" => attachment.attachment_source,
          "rendered_format" => attachment.rendered_format,
          "rendered_payload" => attachment.rendered_payload
        }
      ]
    )
    selection = optimizer_selection(definition: optimized_definition)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.definition["marketplace_entries"]).to eq(optimized_definition["marketplace_entries"])
    expect(agent_run.reload.configuration_bundle_selection_mode).to eq("exploitative")
  end

  it "persists optimizer-selected experiment assignments when reusing the optimizer definition" do
    optimized_definition = optimizer_definition_with_value(12_000)
    optimized_variant = ConfigurationExperimentVariant.find(
      optimized_definition.dig("experiments", "knowledge.token_budget", "configuration_experiment_variant_id")
    )
    selection = optimizer_selection(
      definition: optimized_definition,
      variant_by_experiment_id: { experiment.id => optimized_variant }
    )
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    described_class.call(agent_run: agent_run)

    expect(ConfigurationExperimentAssignment.find_by(configuration_experiment: experiment, agent_run: agent_run))
      .to have_attributes(configuration_experiment_variant_id: optimized_variant.id)
  end

  it "normalizes string experiment ids in optimizer-selected variant maps" do
    optimized_definition = optimizer_definition_with_value(12_000)
    optimized_variant = ConfigurationExperimentVariant.find(
      optimized_definition.dig("experiments", "knowledge.token_budget", "configuration_experiment_variant_id")
    )
    selection = optimizer_selection(
      definition: optimized_definition,
      variant_by_experiment_id: { experiment.id.to_s => optimized_variant }
    )
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    described_class.call(agent_run: agent_run)

    expect(ConfigurationExperimentAssignment.find_by(configuration_experiment: experiment, agent_run: agent_run))
      .to have_attributes(configuration_experiment_variant_id: optimized_variant.id)
  end

  it "persists optimizer-selected experiment assignments from the optimizer definition when the variant map is missing" do
    optimized_definition = optimizer_definition_with_value(12_000)
    selection = optimizer_selection(definition: optimized_definition)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    described_class.call(agent_run: agent_run)

    optimized_variant_id = optimized_definition.dig(
      "experiments",
      "knowledge.token_budget",
      "configuration_experiment_variant_id"
    )
    expect(ConfigurationExperimentAssignment.find_by(configuration_experiment: experiment, agent_run: agent_run))
      .to have_attributes(configuration_experiment_variant_id: optimized_variant_id)
  end

  it "accepts string experiment ids in optimizer definitions when the variant map is missing" do
    optimized_definition = optimizer_definition_with_value(12_000)
    optimized_definition.dig("experiments", "knowledge.token_budget")["configuration_experiment_id"] = experiment.id.to_s
    selection = optimizer_selection(definition: optimized_definition)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    described_class.call(agent_run: agent_run)

    optimized_variant_id = optimized_definition.dig(
      "experiments",
      "knowledge.token_budget",
      "configuration_experiment_variant_id"
    )
    expect(ConfigurationExperimentAssignment.find_by(configuration_experiment: experiment, agent_run: agent_run))
      .to have_attributes(configuration_experiment_variant_id: optimized_variant_id)
  end

  it "accepts optimizer definitions that omit optional empty identity keys when those values are blank for the run" do
    run = create_empty_identity_run
    optimized_definition = optimizer_definition_with_value(12_000, agent_run: run).except(
      "custom_prompt_sha256",
      "model_selection",
      "mcp_servers",
      "service_container_ids"
    )
    optimized_variant_id = optimizer_variant_id(optimized_definition)
    selection = optimizer_selection(definition: optimized_definition, agent_run: run)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: run)

    expect(bundle.definition).to eq(optimized_definition)
    expect(bundle.fingerprint).to eq(selection.fingerprint)
    expect(ConfigurationExperimentAssignment.find_by(configuration_experiment: experiment, agent_run: run))
      .to have_attributes(configuration_experiment_variant_id: optimized_variant_id)
  end

  it "falls back to rebuilding the bundle definition when persisted assignments disagree with the optimizer definition" do
    challenger = create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(12_000))
    selection = optimizer_selection(definition: optimizer_definition_for_variant(variant: challenger, value: 12_000))
    create(:configuration_experiment_assignment,
      configuration_experiment: experiment,
      configuration_experiment_variant: variant,
      agent_run: agent_run)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.fingerprint).to eq(described_class.new(agent_run: agent_run).send(:bundle_fingerprint, bundle.definition))
    expect(bundle.fingerprint).not_to eq(selection.fingerprint)
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to include(
      "configuration_experiment_variant_id" => variant.id,
      "value" => 8000
    )
  end

  it "falls back to rebuilding the bundle definition when the optimizer definition value disagrees with the referenced variant" do
    inconsistent_definition = optimizer_definition_for_variant(variant:, value: 12_000)
    selection = optimizer_selection(definition: inconsistent_definition)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.fingerprint).to eq(described_class.new(agent_run: agent_run).send(:bundle_fingerprint, bundle.definition))
    expect(bundle.fingerprint).not_to eq(selection.fingerprint)
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to include(
      "configuration_experiment_variant_id" => variant.id,
      "value" => 8000
    )
  end

  it "recomputes the fingerprint when the optimizer payload omits it" do
    optimized_definition = optimizer_definition_with_value(12_000)
    selection = optimizer_selection(definition: optimized_definition, fingerprint: nil)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.definition).to eq(optimized_definition)
    expect(bundle.fingerprint).to eq(described_class.new(agent_run: agent_run).send(:bundle_fingerprint, optimized_definition))
  end

  it "falls back to rebuilding the bundle definition when the optimizer definition omits an active experiment" do
    selection = optimizer_selection(definition: optimizer_definition_without_experiments)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.fingerprint).to eq(described_class.new(agent_run: agent_run).send(:bundle_fingerprint, bundle.definition))
    expect(bundle.fingerprint).not_to eq(selection.fingerprint)
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to include(
      "configuration_experiment_id" => experiment.id,
      "configuration_experiment_variant_id" => variant.id,
      "value" => 8000
    )
  end

  it "falls back to rebuilding the bundle definition when the optimizer payload fingerprint is inconsistent" do
    challenger = create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(12_000))
    selection = inconsistent_optimizer_selection(variant_by_experiment_id: { experiment.id => challenger })
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.fingerprint).to eq(described_class.new(agent_run: agent_run).send(:bundle_fingerprint, bundle.definition))
    expect(bundle.fingerprint).not_to eq(selection.fingerprint)
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to include(
      "configuration_experiment_variant_id" => challenger.id,
      "value" => 12_000
    )
  end

  it "falls back to rebuilding the bundle definition when the optimizer definition disagrees with the selected variants" do
    challenger = create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(12_000))
    mismatched_definition = optimizer_definition_for_variant(variant:, value: 8000)
    selection = optimizer_selection(
      definition: mismatched_definition,
      variant_by_experiment_id: { experiment.id => challenger }
    )
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.fingerprint).to eq(described_class.new(agent_run: agent_run).send(:bundle_fingerprint, bundle.definition))
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to include(
      "configuration_experiment_variant_id" => challenger.id,
      "value" => 12_000
    )
  end

  it "rebuilds the bundle definition from scratch when the optimizer-selected variants cannot be reused" do
    selection = optimizer_selection(
      definition: optimizer_definition_without_experiments,
      variant_by_experiment_id: { 999 => variant }
    )
    service = described_class.new(agent_run: agent_run)
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)
    allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_raise(KeyError, "missing experiment")
    allow(service).to receive(:bundle_definition).with(no_args).and_call_original

    bundle = service.call

    expect(bundle.fingerprint).to eq(service.send(:bundle_fingerprint, bundle.definition))
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to include(
      "configuration_experiment_id" => experiment.id,
      "configuration_experiment_variant_id" => variant.id,
      "value" => 8000
    )
  end

  it "persists the fingerprint for the resolved assignment when a run already has an experiment assignment" do
    challenger = create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(12_000))
    create(:configuration_experiment_assignment,
      configuration_experiment: experiment,
      configuration_experiment_variant: variant,
      agent_run: agent_run)

    service = described_class.new(agent_run: agent_run)
    selection = ConfigurationBundles::Optimizer::Selection.new(
      fingerprint: Digest::SHA256.hexdigest("stale optimizer fingerprint"),
      variant_by_experiment_id: { experiment.id => challenger }
    )
    allow(ConfigurationBundles::Optimizer).to receive(:call).and_return(selection)

    bundle = described_class.call(agent_run: agent_run)

    expect(bundle.fingerprint).to eq(service.send(:bundle_fingerprint, bundle.definition))
    expect(bundle.fingerprint).not_to eq(selection.fingerprint)
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to include(
      "configuration_experiment_variant_id" => variant.id,
      "value" => 8000
    )
  end

  def filesystem_mcp_snapshot
    {
      "args" => [ "-y", "@modelcontextprotocol/server-filesystem", "/workspace" ],
      "command" => "npx",
      "env" => { "WORKDIR" => "/workspace" },
      "name" => "filesystem"
    }
  end

  def optimizer_definition_with_value(value, agent_run: self.agent_run)
    matching_variant = experiment.configuration_experiment_variants.find_or_create_by!(config_value: JSON.generate(value)) do |created_variant|
      created_variant.is_control = false
    end
    optimizer_definition_for_variant(variant: matching_variant, value:, agent_run:)
  end

  def optimizer_definition_for_variant(variant:, value:, agent_run: self.agent_run)
    {
      "schema_version" => 1,
      "goal" => agent_run.goal,
      "agent_type" => agent_run.agent_type,
      "provider_id" => agent_run.provider_id,
      "prompt_version_id" => agent_run.prompt_version_id,
      "service_container_ids" => [],
      "mcp_servers" => [ filesystem_mcp_snapshot ],
      "experiments" => {
        "knowledge.token_budget" => {
          "configuration_experiment_id" => experiment.id,
          "configuration_experiment_variant_id" => variant.id,
          "value" => value
        }
      }
    }
  end

  def optimizer_selection(definition:, fingerprint: nil, variant_by_experiment_id: {}, agent_run: self.agent_run)
    ConfigurationBundles::Optimizer::Selection.new(
      definition: definition,
      fingerprint: fingerprint || described_class.new(agent_run: agent_run).send(:bundle_fingerprint, definition),
      variant_by_experiment_id: variant_by_experiment_id,
      selection_mode: "exploitative",
      selection_context: "task"
    )
  end

  def optimizer_definition_without_experiments
    {
      "schema_version" => 1,
      "goal" => agent_run.goal,
      "agent_type" => agent_run.agent_type,
      "provider_id" => agent_run.provider_id,
      "prompt_version_id" => agent_run.prompt_version_id,
      "service_container_ids" => [],
      "mcp_servers" => [ filesystem_mcp_snapshot ],
      "experiments" => {}
    }
  end

  def inconsistent_optimizer_selection(variant_by_experiment_id:)
    ConfigurationBundles::Optimizer::Selection.new(
      definition: optimizer_definition_without_experiments,
      fingerprint: "incorrect",
      variant_by_experiment_id: variant_by_experiment_id,
      selection_mode: "exploitative",
      selection_context: "task"
    )
  end

  def create_empty_identity_run
    create(:agent_run,
      project: project,
      issue: create(:issue, project: project),
      mcp_server_snapshot: [])
  end

  def optimizer_variant_id(definition)
    definition.dig("experiments", "knowledge.token_budget", "configuration_experiment_variant_id")
  end

  def expect_bundle_definition(bundle)
    expect(bundle.definition).to include(
      "schema_version" => 1,
      "goal" => agent_run.goal,
      "agent_type" => agent_run.agent_type
    )
    expect(bundle.definition["model_selection"]).to eq(expected_model_selection)
    expect(bundle.definition["service_container_ids"]).to eq([ first_service.id, second_service.id ].sort)
    expect(bundle.definition["mcp_servers"]).to eq([ filesystem_mcp_snapshot ])
    expect(bundle.definition.dig("experiments", "knowledge.token_budget")).to eq(
      "configuration_experiment_id" => experiment.id,
      "configuration_experiment_variant_id" => variant.id,
      "value" => 8000
    )
  end

  def expect_bundle_identity(bundle)
    expect(bundle.context).to include(
      "identity" => hash_including(
        "fingerprint" => bundle.fingerprint,
        "fingerprint_algorithm" => "sha256",
        "schema_version" => 1
      )
    )
  end
end
