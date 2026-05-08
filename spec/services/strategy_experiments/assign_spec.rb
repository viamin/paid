# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyExperiments::Assign do
  let(:strategy_experiment) { create(:strategy_experiment, status: "running", started_at: Time.current) }
  let!(:control) do
    create(:strategy_experiment_variant,
      strategy_experiment: strategy_experiment,
      strategy_config: strategy_experiment.control_config,
      is_control: true)
  end
  let!(:variant) { create(:strategy_experiment_variant, strategy_experiment: strategy_experiment, strategy_config: JSON.generate("version" => "evolved")) }

  describe ".call" do
    it "creates an assignment for the agent run" do
      agent_run = create(:agent_run)

      assignment = described_class.call(strategy_experiment: strategy_experiment, agent_run: agent_run)

      expect(assignment).to be_persisted
      expect(assignment.strategy_experiment).to eq(strategy_experiment)
      expect(assignment.agent_run).to eq(agent_run)
      expect([ control, variant ]).to include(assignment.strategy_experiment_variant)
    end

    it "returns an existing assignment for duplicate agent runs" do
      agent_run = create(:agent_run)

      first = described_class.call(strategy_experiment: strategy_experiment, agent_run: agent_run)
      second = described_class.call(strategy_experiment: strategy_experiment, agent_run: agent_run)

      expect(second).to eq(first)
    end

    it "raises when the experiment is not running" do
      draft = create(:strategy_experiment, status: "draft")
      create(:strategy_experiment_variant, strategy_experiment: draft, strategy_config: draft.control_config, is_control: true)

      expect {
        described_class.call(strategy_experiment: draft, agent_run: create(:agent_run))
      }.to raise_error(ArgumentError, /not running/)
    end
  end
end
