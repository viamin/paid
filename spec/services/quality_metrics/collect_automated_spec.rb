# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectAutomated do
  describe ".call" do
    it "delegates to QualityMetrics::Collect" do
      agent_run = create(:agent_run, :completed)

      metric = described_class.call(agent_run: agent_run)

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("automated")
      expect(metric.feedback_source).to eq("system")
      expect(metric.composite_score).to be_present
    end

    it "creates automated quality metric for a completed agent run" do
      agent_run = create(:agent_run, :completed, iterations: 3)

      metric = described_class.call(agent_run: agent_run)

      expect(metric).to be_persisted
      expect(metric.scores["pr_created"]).to eq(1.0)
      expect(metric.scores["iterations"]).to eq(0.8) # max(1.0 - (3-1)*0.1, 0.0)
      expect(metric.scores["lint_clean"]).to eq(1.0)
    end

    it "updates existing automated metric on re-collection" do
      agent_run = create(:agent_run, :completed)
      first = described_class.call(agent_run: agent_run)
      second = described_class.call(agent_run: agent_run)

      expect(first.id).to eq(second.id)
    end
  end
end
