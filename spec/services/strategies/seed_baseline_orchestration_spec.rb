# frozen_string_literal: true

require "rails_helper"

RSpec.describe Strategies::SeedBaselineOrchestration do
  describe ".call" do
    it "ensures active global strategies with promoted baseline versions exist" do
      described_class.call

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

    it "promotes a new baseline version when the current content drifts" do
      described_class.call

      definition = Strategies::BaselineOrchestration.definitions.first
      strategy = Strategy.global.find_by!(slug: definition[:slug])
      replacement = create_drifted_current_version!(strategy, definition)

      expect {
        described_class.call
      }.to change { strategy.reload.strategy_versions.count }.by(1)

      expect(strategy.reload.current_version).to be_active
      expect(strategy.current_version.content).to eq(definition[:content])
      expect(strategy.current_version.provenance).to include(
        "source" => "baseline_workflow_extraction",
        "decision_type" => definition[:decision_type]
      )
      expect(replacement.reload).to be_retired
    end

    def create_drifted_current_version!(strategy, definition)
      strategy.current_version.update!(
        promotion_state: "retired",
        retired_at: 1.day.ago
      )
      strategy.create_version!(
        content: { "drifted" => true },
        provenance: {
          "source" => "manual_override",
          "decision_type" => definition[:decision_type]
        },
        promotion_state: "active",
        created_by: "seed",
        reasoning: "Temporary drift",
        change_notes: "Drifted from extracted baseline.",
        promoted_at: 1.hour.ago
      ).tap { |version| strategy.update!(current_version: version) }
    end
  end
end
