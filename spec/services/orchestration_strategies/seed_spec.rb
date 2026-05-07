# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrchestrationStrategies::Seed do
  describe ".call" do
    it "creates one active strategy per type" do
      expect { described_class.call }.to change(OrchestrationStrategy, :count)
        .by(OrchestrationStrategy::STRATEGY_TYPES.size)

      OrchestrationStrategy::STRATEGY_TYPES.each do |type|
        strategy = OrchestrationStrategy.system_defaults.by_type(type).active.first
        expect(strategy).to be_present, "Expected system default for #{type}"
        expect(strategy.configuration).to eq(
          OrchestrationStrategies::Defaults.configuration_for(type)
        )
      end
    end

    it "is idempotent — running twice does not duplicate records" do
      described_class.call
      expect { described_class.call }.not_to change(OrchestrationStrategy, :count)
    end

    it "returns only newly created records" do
      first_run = described_class.call
      expect(first_run.size).to eq(OrchestrationStrategy::STRATEGY_TYPES.size)

      second_run = described_class.call
      expect(second_run).to be_empty
    end

    it "fills in missing types when some already exist" do
      create(:orchestration_strategy, :review_settings)

      created = described_class.call
      expect(created.map(&:strategy_type)).not_to include("review_settings")
      expect(created.size).to eq(OrchestrationStrategy::STRATEGY_TYPES.size - 1)
    end
  end
end
