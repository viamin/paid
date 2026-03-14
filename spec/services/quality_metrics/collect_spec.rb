# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::Collect do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :completed, iterations: 3) }

    it "creates a quality metric for the agent run" do
      expect { described_class.call(agent_run: agent_run) }.to change(QualityMetric, :count).by(1)
    end

    it "sets iterations from the agent run" do
      metric = described_class.call(agent_run: agent_run)

      expect(metric.iterations_to_complete).to eq(3)
    end

    it "calculates a composite score" do
      metric = described_class.call(agent_run: agent_run)

      expect(metric.quality_score).to be_present
    end

    it "does not create duplicate metrics" do
      described_class.call(agent_run: agent_run)

      expect { described_class.call(agent_run: agent_run) }.not_to change(QualityMetric, :count)
    end
  end
end
