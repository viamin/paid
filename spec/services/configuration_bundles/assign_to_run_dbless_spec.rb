# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::AssignToRun, :no_db do
  let(:project) { Struct.new(:account, :service_container_ids).new(account, []) }
  let(:account) { Object.new }
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

  describe "#call" do
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

    it "falls back to rebuilding the bundle payload when the optimizer fingerprint is inconsistent" do
      fallback_definition = selection_definition.merge(
        "experiments" => {
          "knowledge.token_budget" => { "value" => 8000 }
        }
      )
      selection = optimizer_selection(
        definition: selection_definition,
        fingerprint: "incorrect",
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
  end

  def selection_definition
    {
      "schema_version" => 1,
      "goal" => "create_pr",
      "agent_type" => "claude_code",
      "experiments" => {}
    }
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
end
