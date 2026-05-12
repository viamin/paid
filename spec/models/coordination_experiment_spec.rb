# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationExperiment do
  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:policy_name) }
    it { is_expected.to validate_inclusion_of(:policy_name).in_array([ described_class::POLICY_NAME ]) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
  end

  describe ".active_for" do
    let(:account) { create(:account) }

    it "returns the running experiment when workflow traffic is included" do
      experiment = create(:coordination_experiment, account: account, traffic_percentage: 100)

      expect(described_class.active_for(account:, workflow_id: "wf-1")).to eq(experiment)
    end

    it "returns nil when the traffic gate excludes the workflow" do
      create(:coordination_experiment, account: account, traffic_percentage: 0)

      expect(described_class.active_for(account:, workflow_id: "wf-1")).to be_nil
    end
  end

  describe "#effective_policy_for" do
    it "merges variant overrides onto the experiment baseline policy" do
      experiment = create(:coordination_experiment,
        control_policy: {
          "parallel_execution" => { "max_batch_size" => 3, "cancel_remaining_on_failure" => false },
          "decomposition" => { "enabled" => true, "max_tasks" => 6 }
        })
      variant = create(:coordination_experiment_variant,
        coordination_experiment: experiment,
        policy_config: {
          "parallel_execution" => { "max_batch_size" => 1 }
        })

      expect(experiment.effective_policy_for(variant)).to include(
        "parallel_execution" => {
          "max_batch_size" => 1,
          "cancel_remaining_on_failure" => false
        },
        "decomposition" => {
          "enabled" => true,
          "max_tasks" => 6
        }
      )
    end
  end
end
