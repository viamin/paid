# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationExperiments::Create do
  describe ".call" do
    let(:account) { create(:account) }

    it "creates a draft experiment with control and variant values" do
      experiment = described_class.call(
        account: account,
        name: "Knowledge token budget",
        config_key: "knowledge.token_budget",
        control_value: 4000,
        variant_values: [ 6000 ],
        experiment_type: "agent_output"
      )

      expect(experiment).to be_persisted
      expect(experiment.account).to eq(account)
      expect(experiment.status).to eq("draft")
      expect(experiment.control_value).to eq("4000")
      expect(experiment.configuration_experiment_variants.size).to eq(2)
      expect(experiment.control_variant.parsed_value).to eq(4000)
    end

    it "rejects duplicate variant values" do
      expect {
        described_class.call(
          name: "Knowledge token budget",
          config_key: "knowledge.token_budget",
          control_value: 4000,
          variant_values: [ 6000, 6000 ],
          experiment_type: "agent_output"
        )
      }.to raise_error(ArgumentError, /unique/)
    end
  end
end
