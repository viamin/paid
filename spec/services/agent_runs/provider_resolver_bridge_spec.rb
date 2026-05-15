# frozen_string_literal: true

require "rails_helper"

class ProviderResolverBridgeProject
end

RSpec.describe AgentRuns::ProviderResolver, :no_db do
  describe ".call" do
    it "accepts requested_provider_id as a legacy alias for requested_runner_id" do
      project = instance_double(ProviderResolverBridgeProject)
      resolver = instance_double(described_class, call: [ 123, "claude_code" ])

      allow(described_class).to receive(:new).and_return(resolver)

      described_class.call(project: project, goal: "create_pr", requested_provider_id: 123)

      expect(described_class).to have_received(:new).with(
        project: project,
        goal: "create_pr",
        requested_runner_id: 123
      )
    end
  end

  describe ".selected_provider" do
    it "delegates to the runner-named bridge" do
      project = instance_double(ProviderResolverBridgeProject)

      allow(described_class).to receive(:selected_runner).with(project: project, runner_id: 456).and_return(:runner)

      expect(described_class.selected_provider(project: project, provider_id: 456)).to eq(:runner)
    end
  end
end
