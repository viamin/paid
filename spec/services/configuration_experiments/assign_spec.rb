# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationExperiments::Assign do
  let(:configuration_experiment) { create(:configuration_experiment, status: "running", started_at: Time.current) }
  let!(:control) do
    create(:configuration_experiment_variant,
      configuration_experiment: configuration_experiment,
      config_value: configuration_experiment.control_value,
      is_control: true)
  end
  let!(:variant) { create(:configuration_experiment_variant, configuration_experiment: configuration_experiment, config_value: JSON.generate(6000)) }

  describe ".call" do
    it "creates an assignment for the agent run" do
      agent_run = create(:agent_run)

      assignment = described_class.call(configuration_experiment: configuration_experiment, agent_run: agent_run)

      expect(assignment).to be_persisted
      expect(assignment.configuration_experiment).to eq(configuration_experiment)
      expect(assignment.agent_run).to eq(agent_run)
      expect([ control, variant ]).to include(assignment.configuration_experiment_variant)
    end

    it "returns an existing assignment for duplicate agent runs" do
      agent_run = create(:agent_run)

      first = described_class.call(configuration_experiment: configuration_experiment, agent_run: agent_run)
      second = described_class.call(configuration_experiment: configuration_experiment, agent_run: agent_run)

      expect(second).to eq(first)
    end

    it "raises when the experiment is not running" do
      draft = create(:configuration_experiment, status: "draft")
      create(:configuration_experiment_variant, configuration_experiment: draft, config_value: draft.control_value, is_control: true)

      expect {
        described_class.call(configuration_experiment: draft, agent_run: create(:agent_run))
      }.to raise_error(ArgumentError, /not running/)
    end
  end
end
