# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyExperiment do
  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:strategy_name) }
    it { is_expected.to validate_inclusion_of(:strategy_name).in_array(described_class::STRATEGY_NAMES) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_presence_of(:control_config) }
  end

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:winner_variant).class_name("StrategyExperimentVariant").optional }
    it { is_expected.to have_many(:strategy_experiment_variants).dependent(:destroy) }
    it { is_expected.to have_many(:strategy_experiment_assignments).dependent(:destroy) }
  end

  describe "#start!" do
    it "transitions from draft to running" do
      experiment = create(:strategy_experiment, status: "draft")

      experiment.start!

      expect(experiment.reload.status).to eq("running")
      expect(experiment.started_at).to be_present
    end

    it "raises when not in draft status" do
      experiment = create(:strategy_experiment, status: "running", started_at: Time.current)

      expect { experiment.start! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#complete!" do
    it "transitions from running to completed" do
      experiment = create(:strategy_experiment, status: "running", started_at: Time.current)

      experiment.complete!

      expect(experiment.reload.status).to eq("completed")
      expect(experiment.completed_at).to be_present
    end

    it "accepts a winner variant" do
      experiment = create(:strategy_experiment, status: "running", started_at: Time.current)
      variant = create(:strategy_experiment_variant, strategy_experiment: experiment)

      experiment.complete!(winner: variant)

      expect(experiment.reload.winner_variant).to eq(variant)
    end
  end

  describe "#cancel!" do
    it "transitions from running to cancelled" do
      experiment = create(:strategy_experiment, status: "running", started_at: Time.current)

      experiment.cancel!

      expect(experiment.reload.status).to eq("cancelled")
    end

    it "transitions from draft to cancelled" do
      experiment = create(:strategy_experiment, status: "draft")

      experiment.cancel!

      expect(experiment.reload.status).to eq("cancelled")
    end
  end

  describe ".active_for" do
    it "returns a running experiment for the given strategy and account" do
      account = create(:account)
      experiment = create(:strategy_experiment, account: account, strategy_name: "auto_review", status: "running", started_at: Time.current)

      result = described_class.active_for("auto_review", account: account)

      expect(result).to eq(experiment)
    end

    it "returns nil when no running experiment exists" do
      account = create(:account)
      create(:strategy_experiment, account: account, strategy_name: "auto_review", status: "draft")

      result = described_class.active_for("auto_review", account: account)

      expect(result).to be_nil
    end
  end

  describe "#sufficient_samples?" do
    it "returns true when all variants meet the minimum" do
      experiment = create(:strategy_experiment, min_samples_per_variant: 2)
      create(:strategy_experiment_variant, strategy_experiment: experiment, is_control: true, sample_count: 2)
      create(:strategy_experiment_variant, strategy_experiment: experiment, sample_count: 3)

      expect(experiment.sufficient_samples?).to be true
    end

    it "returns false when any variant is below the minimum" do
      experiment = create(:strategy_experiment, min_samples_per_variant: 5)
      create(:strategy_experiment_variant, strategy_experiment: experiment, is_control: true, sample_count: 5)
      create(:strategy_experiment_variant, strategy_experiment: experiment, sample_count: 2)

      expect(experiment.sufficient_samples?).to be false
    end
  end
end
