# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::TrendAnalysis do
  describe ".call" do
    it "returns rolling average for prompt version" do
      prompt = create(:prompt, :with_version)
      version = prompt.current_version

      create(:quality_metric, prompt_version: version, composite_score: 0.8)
      create(:quality_metric, :human, prompt_version: version, composite_score: 0.9)

      result = described_class.call(prompt_version_id: version.id)

      expect(result[:rolling_average]).to eq(0.85)
      expect(result[:sample_size]).to eq(2)
      expect(result[:min_score]).to eq(0.8)
      expect(result[:max_score]).to eq(0.9)
    end

    it "returns rolling average for project" do
      project = create(:project)
      run1 = create(:agent_run, project: project)
      run2 = create(:agent_run, :with_custom_prompt, project: project)
      create(:quality_metric, agent_run: run1, composite_score: 0.7)
      create(:quality_metric, :human, agent_run: run2, composite_score: 0.9)

      result = described_class.call(project_id: project.id)

      expect(result[:rolling_average]).to eq(0.8)
      expect(result[:sample_size]).to eq(2)
    end

    it "respects window size" do
      3.times { create(:quality_metric, :human, composite_score: 0.5) }

      result = described_class.call(window_size: 2)

      expect(result[:sample_size]).to eq(2)
    end

    it "returns nil average when no metrics exist" do
      result = described_class.call(prompt_version_id: -1)

      expect(result[:rolling_average]).to be_nil
      expect(result[:sample_size]).to eq(0)
    end
  end
end
