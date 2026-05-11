# frozen_string_literal: true

require "rails_helper"

RSpec.describe Strategies::SeedBaselineOrchestration do
  describe ".call" do
    it "creates active global strategies with promoted baseline versions" do
      expect { described_class.call }.to change(Strategy, :count).by(3)
        .and change(StrategyVersion, :count).by(3)

      Strategies::BaselineOrchestration.definitions.each do |definition|
        strategy = Strategy.global.find_by!(slug: definition[:slug])

        expect(strategy).to have_attributes(
          decision_type: definition[:decision_type],
          status: "active"
        )
        expect(strategy.current_version).to be_present
        expect(strategy.current_version).to be_active
        expect(strategy.current_version.content).to eq(definition[:content])
        expect(strategy.current_version.provenance).to include(
          "source" => "baseline_workflow_extraction",
          "decision_type" => definition[:decision_type]
        )
      end
    end

    it "is idempotent when the baseline content is already current" do
      described_class.call

      expect { described_class.call }.not_to change(Strategy, :count)
      expect { described_class.call }.not_to change(StrategyVersion, :count)
    end
  end
end
