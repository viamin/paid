# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::AssignToRun, :no_db do
  let(:project) { Struct.new(:account, :service_container_ids).new(account, []) }
  let(:account) do
    Struct.new(:id) do
      def with_lock
        yield
      end
    end.new(99)
  end
  let(:agent_run) do
    Struct.new(
      :id,
      :project,
      :goal,
      :agent_type,
      :provider_id,
      :prompt_version_id,
      :custom_prompt,
      :model_selection,
      :service_container_ids,
      :mcp_server_snapshot,
      keyword_init: true
    ) do
      attr_reader :update_arguments

      def update!(attributes)
        @update_arguments = attributes
      end
    end.new(
      id: 123,
      project: project,
      goal: "create_pr",
      agent_type: "claude_code",
      provider_id: 12,
      prompt_version_id: 34,
      custom_prompt: nil,
      model_selection: nil,
      service_container_ids: [],
      mcp_server_snapshot: []
    )
  end
  let(:service) { described_class.new(agent_run: agent_run) }
  let(:bundle) { Struct.new(:definition, :fingerprint).new({}, "bundle") }
  let(:experiment) { Struct.new(:id, :config_key).new(42, "knowledge.token_budget") }
  let(:selected_variant) do
    Struct.new(:id, :parsed_value, :configuration_experiment).new(7, 12_000, experiment)
  end

  describe "#call" do
    before do
      allow(service).to receive(:active_experiments).and_return([])
    end

    it "uses the optimizer-provided definition and fingerprint when they are consistent" do
      optimized_definition = selection_definition
      selection = optimizer_selection(definition: optimized_definition)

      allow(service).to receive(:optimizer_selection).and_return(selection)
      expect_bundle_lookup(definition: optimized_definition, fingerprint: selection.fingerprint)
      expect(agent_run).to receive(:update!).with(expected_update_arguments)

      expect(service.call).to eq(bundle)
    end

    it "recomputes the fingerprint when the optimizer omits it" do
      optimized_definition = selection_definition
      selection = optimizer_selection(definition: optimized_definition, fingerprint: nil)
      computed_fingerprint = bundle_fingerprint(optimized_definition)

      allow(service).to receive(:optimizer_selection).and_return(selection)
      expect_bundle_lookup(definition: optimized_definition, fingerprint: computed_fingerprint)
      expect(agent_run).to receive(:update!).with(expected_update_arguments)

      expect(service.call).to eq(bundle)
    end

    it "persists assignments from the optimizer definition when the variant map is missing" do
      setup_definition_only_optimizer_selection

      expect(service.call).to eq(bundle)
    end

    it "accepts optimizer definitions that omit optional empty identity keys" do
      setup_optional_identity_keys_omitted_selection

      expect(service.call).to eq(bundle)
    end

    it "falls back to rebuilding the bundle payload when persisted assignments disagree with the optimizer definition" do
      setup_assignment_mismatch_fallback

      expect(service.call).to eq(bundle)
    end

    it "falls back to rebuilding the bundle payload when the optimizer definition value disagrees with the referenced variant" do
      fallback_definition = experiment_definition_for(8000)
      inconsistent_definition = experiment_definition_for(selected_variant.parsed_value)
      selection = optimizer_selection(definition: inconsistent_definition)
      referenced_variant = build_assignment_variant(8, 8000)

      allow(service).to receive_messages(
        optimizer_selection: selection,
        optimizer_assignment_inputs_from_definition: [ [ experiment, referenced_variant ] ]
      )
      allow(service).to receive(:optimizer_definition_variant_matches?).and_return(false)
      allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_return(fallback_definition)
      expect_bundle_lookup(
        definition: fallback_definition,
        fingerprint: bundle_fingerprint(fallback_definition)
      )

      service.call
    end

    it "falls back to rebuilding the bundle payload when the optimizer fingerprint is inconsistent" do
      fallback_definition = selection_definition.merge(
        "experiments" => {
          "knowledge.token_budget" => { "value" => 8000 }
        }
      )
      selection = optimizer_selection(
        definition: selection_definition,
        fingerprint: "incorrect",
        variant_by_experiment_id: { experiment.id => build_assignment_variant(8, 8000) }
      )

      allow(service).to receive(:optimizer_selection).and_return(selection)
      allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_return(fallback_definition)
      expect_bundle_lookup(
        definition: fallback_definition,
        fingerprint: bundle_fingerprint(fallback_definition)
      )

      service.call
    end

    it "falls back to rebuilding the bundle payload when the optimizer definition omits an active experiment" do
      fallback_definition = experiment_definition_for(8000)
      selection = optimizer_selection(definition: selection_definition)

      allow(service).to receive_messages(
        optimizer_selection: selection,
        active_experiments: [ experiment ]
      )
      allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_return(fallback_definition)
      expect_bundle_lookup(
        definition: fallback_definition,
        fingerprint: bundle_fingerprint(fallback_definition)
      )

      service.call
    end

    it "falls back to rebuilding the bundle payload when the optimizer definition references a stale experiment id" do
      fallback_definition = experiment_definition_for(8000)
      stale_definition = experiment_definition_for(selected_variant.parsed_value).deep_dup
      stale_definition.dig("experiments", "knowledge.token_budget")["configuration_experiment_id"] = 999
      selection = optimizer_selection(definition: stale_definition)

      allow(service).to receive_messages(
        optimizer_selection: selection,
        active_experiments: [ experiment ]
      )
      allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_return(fallback_definition)
      expect_bundle_lookup(
        definition: fallback_definition,
        fingerprint: bundle_fingerprint(fallback_definition)
      )

      service.call
    end

    it "falls back to rebuilding the bundle payload when the optimizer definition omits required run attributes" do
      fallback_definition = selection_definition.merge(
        "experiments" => {
          "knowledge.token_budget" => { "value" => 8000 }
        }
      )
      incomplete_definition = selection_definition.except("provider_id")
      selection = optimizer_selection(
        definition: incomplete_definition,
        fingerprint: bundle_fingerprint(incomplete_definition),
        variant_by_experiment_id: { 42 => Object.new }
      )

      allow(service).to receive(:optimizer_selection).and_return(selection)
      allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_return(fallback_definition)
      expect_bundle_lookup(
        definition: fallback_definition,
        fingerprint: bundle_fingerprint(fallback_definition)
      )

      service.call
    end

    it "falls back to rebuilding the bundle payload when the optimizer definition disagrees with the selected variants" do
      fallback_definition = experiment_definition_for(selected_variant.parsed_value)
      mismatched_definition = experiment_definition_for(8000)
      selection = optimizer_selection(
        definition: mismatched_definition,
        fingerprint: bundle_fingerprint(mismatched_definition),
        variant_by_experiment_id: { experiment.id => selected_variant }
      )

      allow(service).to receive(:optimizer_selection).and_return(selection)
      allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_return(fallback_definition)
      expect_bundle_lookup(
        definition: fallback_definition,
        fingerprint: bundle_fingerprint(fallback_definition)
      )

      service.call
    end

    it "falls back to rebuilding the bundle payload when the optimizer variant map references an inactive experiment" do
      fallback_definition = experiment_definition_for(selected_variant.parsed_value)
      selection = optimizer_selection(
        definition: fallback_definition,
        variant_by_experiment_id: { 999 => selected_variant }
      )

      allow(service).to receive_messages(
        optimizer_selection: selection,
        active_experiments: [ experiment ]
      )
      allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_raise(KeyError, "missing experiment")
      allow(service).to receive(:bundle_definition).with(no_args).and_return(fallback_definition)
      expect_bundle_lookup(
        definition: fallback_definition,
        fingerprint: bundle_fingerprint(fallback_definition)
      )

      service.call
    end

    it "falls back to rebuilding the bundle payload when the optimizer variant belongs to another experiment" do
      setup_mismatched_variant_fallback

      expect(service.call).to eq(bundle)
    end

    it "rebuilds the bundle payload from scratch when optimizer-selected variants cannot be reused" do
      selection = optimizer_selection(
        definition: selection_definition,
        variant_by_experiment_id: { 999 => selected_variant }
      )
      fallback_definition = experiment_definition_for(selected_variant.parsed_value)

      allow(service).to receive(:optimizer_selection).and_return(selection)
      allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_raise(KeyError, "missing experiment")
      allow(service).to receive(:bundle_definition).with(no_args).and_return(fallback_definition)
      expect_bundle_lookup(
        definition: fallback_definition,
        fingerprint: bundle_fingerprint(fallback_definition)
      )

      service.call
    end
  end

  describe "#find_or_create_bundle" do
    let(:definition) { { "schema_version" => 1 } }
    let(:fingerprint) { "fingerprint" }
    let(:bundle_scope) { instance_double(ActiveRecord::Relation) }

    before do
      allow(service).to receive(:bundle_scope).and_return(bundle_scope)
    end

    it "raises when a conflicting bundle appears after the initial lookup" do
      allow(bundle_scope).to receive(:find_by).with(fingerprint: fingerprint).and_return(nil, bundle)

      expect do
        service.send(:find_or_create_bundle, fingerprint:, definition:)
      end.to raise_error(
        ConfigurationBundles::AssignToRun::FingerprintMismatchError,
        "Configuration bundle fingerprint collision for account 99"
      )
    end

    it "raises when the retry lookup after a uniqueness race finds a conflicting bundle" do
      allow(bundle_scope).to receive(:find_by).with(fingerprint: fingerprint).and_return(nil, nil)
      allow(service).to receive(:create_runtime_bundle)
        .with(fingerprint:, definition:)
        .and_raise(ActiveRecord::RecordNotUnique)
      allow(bundle_scope).to receive(:find_by!).with(fingerprint: fingerprint).and_return(bundle)

      expect do
        service.send(:find_or_create_bundle, fingerprint:, definition:)
      end.to raise_error(
        ConfigurationBundles::AssignToRun::FingerprintMismatchError,
        "Configuration bundle fingerprint collision for account 99"
      )
    end
  end

  def selection_definition
    {
      "schema_version" => 1,
      "goal" => "create_pr",
      "agent_type" => "claude_code",
      "provider_id" => 12,
      "prompt_version_id" => 34,
      "service_container_ids" => [],
      "mcp_servers" => [],
      "experiments" => {}
    }
  end

  def experiment_definition_for(value)
    selection_definition.merge(
      "experiments" => {
        "knowledge.token_budget" => {
          "configuration_experiment_id" => experiment.id,
          "configuration_experiment_variant_id" => selected_variant.id,
          "value" => value
        }
      }
    )
  end

  def optimizer_selection(definition:, fingerprint: bundle_fingerprint(definition), variant_by_experiment_id: {})
    ConfigurationBundles::Optimizer::Selection.new(
      definition: definition,
      fingerprint: fingerprint,
      variant_by_experiment_id: variant_by_experiment_id,
      selection_mode: "exploitative",
      selection_context: "task"
    )
  end

  def expected_update_arguments
    {
      configuration_bundle: bundle,
      configuration_bundle_selection_mode: "exploitative",
      configuration_bundle_selection_context: "task"
    }
  end

  def expect_bundle_lookup(definition:, fingerprint:)
    expect(service).to receive(:find_or_create_bundle).with(
      fingerprint: fingerprint,
      definition: definition
    ).and_return(bundle)
  end

  def bundle_fingerprint(definition)
    service.send(:bundle_fingerprint, definition)
  end

  def setup_assignment_mismatch_fallback
    optimized_definition = experiment_definition_for(selected_variant.parsed_value)
    selection = optimizer_selection(definition: optimized_definition)
    optimizer_variant = build_assignment_variant(selected_variant.id, selected_variant.parsed_value)
    persisted_variant = Struct.new(:id, :parsed_value, :configuration_experiment).new(8, 8000, experiment)
    assignment = Struct.new(:configuration_experiment_variant).new(persisted_variant)
    fallback_definition = optimizer_definition_for_variant(persisted_variant)

    allow(service).to receive_messages(
      optimizer_selection: selection,
      active_experiments: [ experiment ],
      optimizer_assignment_inputs_from_definition: [ [ experiment, optimizer_variant ] ]
    )
    expect(ConfigurationExperiments::Assign).to receive(:call).with(
      configuration_experiment: experiment,
      agent_run: agent_run,
      variant: optimizer_variant
    ).and_return(assignment)
    expect(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_return(fallback_definition)
    expect_bundle_lookup(
      definition: fallback_definition,
      fingerprint: bundle_fingerprint(fallback_definition)
    )
    expect(agent_run).to receive(:update!).with(expected_update_arguments)
  end

  def setup_definition_only_optimizer_selection
    optimized_definition = experiment_definition_for(selected_variant.parsed_value)
    selection = optimizer_selection(definition: optimized_definition)
    variant_record = build_assignment_variant(selected_variant.id, selected_variant.parsed_value)
    assignment = Struct.new(:configuration_experiment_variant).new(variant_record)

    allow(service).to receive_messages(
      optimizer_selection: selection,
      active_experiments: [ experiment ],
      optimizer_assignment_inputs_from_definition: [ [ experiment, variant_record ] ]
    )
    expect(ConfigurationExperiments::Assign).to receive(:call).with(
      configuration_experiment: experiment,
      agent_run: agent_run,
      variant: variant_record
    ).and_return(assignment)
    expect_bundle_lookup(definition: optimized_definition, fingerprint: selection.fingerprint)
    expect(agent_run).to receive(:update!).with(expected_update_arguments)
  end

  def setup_optional_identity_keys_omitted_selection
    optimized_definition = experiment_definition_for(selected_variant.parsed_value).except(
      "custom_prompt_sha256",
      "model_selection",
      "mcp_servers",
      "service_container_ids"
    )
    selection = optimizer_selection(definition: optimized_definition)
    variant_record = build_assignment_variant(selected_variant.id, selected_variant.parsed_value)
    assignment = Struct.new(:configuration_experiment_variant).new(variant_record)

    allow(service).to receive_messages(
      optimizer_selection: selection,
      active_experiments: [ experiment ],
      optimizer_assignment_inputs_from_definition: [ [ experiment, variant_record ] ]
    )
    expect(ConfigurationExperiments::Assign).to receive(:call).with(
      configuration_experiment: experiment,
      agent_run: agent_run,
      variant: variant_record
    ).and_return(assignment)
    expect_bundle_lookup(definition: optimized_definition, fingerprint: selection.fingerprint)
    expect(agent_run).to receive(:update!).with(expected_update_arguments)
  end

  def build_assignment_variant(id, parsed_value)
    Struct.new(:id, :parsed_value, :configuration_experiment_id, :configuration_experiment).new(
      id,
      parsed_value,
      experiment.id,
      experiment
    )
  end

  def setup_mismatched_variant_fallback
    fallback_definition = experiment_definition_for(selected_variant.parsed_value)
    mismatched_variant = Struct.new(
      :id,
      :parsed_value,
      :configuration_experiment_id,
      :configuration_experiment
    ).new(selected_variant.id, selected_variant.parsed_value, 999, nil)
    selection = optimizer_selection(
      definition: fallback_definition,
      variant_by_experiment_id: { experiment.id => mismatched_variant }
    )

    allow(service).to receive_messages(
      optimizer_selection: selection,
      active_experiments: [ experiment ]
    )
    allow(service).to receive(:bundle_definition).with(selection.variant_by_experiment_id).and_return(fallback_definition)
    expect_bundle_lookup(
      definition: fallback_definition,
      fingerprint: bundle_fingerprint(fallback_definition)
    )
  end

  def optimizer_definition_for_variant(variant)
    experiment_definition_for(variant.parsed_value).merge(
      "experiments" => {
        "knowledge.token_budget" => {
          "configuration_experiment_id" => experiment.id,
          "configuration_experiment_variant_id" => variant.id,
          "value" => variant.parsed_value
        }
      }
    )
  end
end
