# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationExperiment do
  describe "associations" do
    it { is_expected.to belong_to(:account).optional }
    it { is_expected.to have_many(:configuration_experiment_variants).dependent(:destroy) }
    it { is_expected.to have_many(:configuration_experiment_assignments).dependent(:destroy) }
    it { is_expected.to belong_to(:winner_variant).class_name("ConfigurationExperimentVariant").optional }
  end

  describe ".active_for" do
    let(:project) { create(:project) }
    let(:agent_run) { create(:agent_run, project: project) }

    it "returns the running experiment for the config key" do
      experiment = create(:configuration_experiment, account: project.account, status: "running", config_key: "knowledge.token_budget")

      expect(described_class.active_for("knowledge.token_budget", project: project, agent_run: agent_run)).to eq(experiment)
    end

    it "prefers account-specific experiments over global experiments" do
      global = create(:configuration_experiment, account: nil, status: "running", config_key: "knowledge.token_budget")
      experiment = create(:configuration_experiment, account: project.account, status: "running", config_key: "knowledge.token_budget")

      expect(described_class.active_for("knowledge.token_budget", project: project, agent_run: agent_run)).to eq(experiment)
      expect(described_class.active_for("knowledge.token_budget", agent_run: agent_run)).to eq(global)
    end

    it "does not return another account's experiment" do
      create(:configuration_experiment, status: "running", config_key: "knowledge.token_budget")

      expect(described_class.active_for("knowledge.token_budget", project: project, agent_run: agent_run)).to be_nil
    end

    it "does not return experiments outside their traffic rollout" do
      create(:configuration_experiment, account: project.account, status: "running", config_key: "knowledge.token_budget", traffic_percentage: 0)

      expect(described_class.active_for("knowledge.token_budget", project: project, agent_run: agent_run)).to be_nil
    end
  end

  describe "#start!" do
    it "starts a draft experiment" do
      experiment = create(:configuration_experiment)

      experiment.start!

      expect(experiment.status).to eq("running")
      expect(experiment.started_at).to be_present
    end
  end
end
