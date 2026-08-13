# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectHumanFeedback do
  describe ".call" do
    it "creates human quality metric for a merged PR" do
      agent_run = create(:agent_run, :completed)

      metric = described_class.call(agent_run: agent_run, pr_merged: true)

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("human")
      expect(metric.feedback_source).to eq("pr_merge")
      expect(metric.scores["pr_merged"]).to eq(1.0)
      expect(metric.composite_score).to eq(1.0)
    end

    it "scores pr_merged as 0.0 when PR is not merged" do
      agent_run = create(:agent_run, :completed)

      metric = described_class.call(agent_run: agent_run, pr_merged: false)

      expect(metric.scores["pr_merged"]).to eq(0.0)
    end

    it "associates the prompt version from the agent run" do
      prompt = create(:prompt, :with_version)
      agent_run = create(:agent_run, :completed, prompt_version: prompt.current_version)

      metric = described_class.call(agent_run: agent_run, pr_merged: true)

      expect(metric.prompt_version).to eq(prompt.current_version)
    end

    it "updates existing human metric on re-collection" do
      agent_run = create(:agent_run, :completed)
      first = described_class.call(agent_run: agent_run, pr_merged: false)
      second = described_class.call(agent_run: agent_run, pr_merged: true)

      expect(first.id).to eq(second.id)
      expect(second.scores["pr_merged"]).to eq(1.0)
    end

    it "supports custom feedback source" do
      agent_run = create(:agent_run, :completed)

      metric = described_class.call(
        agent_run: agent_run,
        pr_merged: true,
        feedback_source: "pr_review"
      )

      expect(metric.feedback_source).to eq("pr_review")
    end
  end
end
