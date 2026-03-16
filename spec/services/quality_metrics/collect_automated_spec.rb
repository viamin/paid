# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectAutomated do
  describe ".call" do
    it "creates automated quality metric for a completed agent run" do
      agent_run = create(:agent_run, :completed, iterations: 3)

      metric = described_class.call(agent_run: agent_run)

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("automated")
      expect(metric.feedback_source).to eq("system")
      expect(metric.scores["pr_created"]).to eq(1.0)
      expect(metric.scores["ci_passed"]).to eq(1.0)
      expect(metric.scores["iterations"]).to eq(0.8) # max(1.0 - (3-1)*0.1, 0.0)
      expect(metric.scores["lint_clean"]).to eq(1.0)
      expect(metric.scores["tests_pass"]).to eq(1.0)
      expect(metric.composite_score).to be_present
    end

    it "scores pr_created as 0.0 when no PR exists" do
      agent_run = create(:agent_run, :failed)

      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["pr_created"]).to eq(0.0)
    end

    it "scores ci_passed as 0.0 for failed runs" do
      agent_run = create(:agent_run, :failed)

      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["ci_passed"]).to eq(0.0)
    end

    it "normalizes iterations correctly" do
      agent_run = create(:agent_run, :completed, iterations: 1)
      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["iterations"]).to eq(1.0)
    end

    it "caps iteration score at 0.0 for high iterations" do
      agent_run = create(:agent_run, :completed, iterations: 15)
      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["iterations"]).to eq(0.0)
    end

    it "associates the prompt version from the agent run" do
      prompt = create(:prompt, :with_version)
      agent_run = create(:agent_run, :completed, prompt_version: prompt.current_version)

      metric = described_class.call(agent_run: agent_run)

      expect(metric.prompt_version).to eq(prompt.current_version)
    end

    it "updates existing automated metric on re-collection" do
      agent_run = create(:agent_run, :completed)
      first = described_class.call(agent_run: agent_run)
      second = described_class.call(agent_run: agent_run)

      expect(first.id).to eq(second.id)
    end
  end
end
