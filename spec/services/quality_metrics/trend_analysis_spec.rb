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

    it "excludes operational failures from rolling average" do
      project = create(:project)
      good_run = create(:agent_run, project: project)
      create(:quality_metric, agent_run: good_run, composite_score: 0.9)

      timeout_run = create(:agent_run, status: "timeout", project: project)
      create(:quality_metric, agent_run: timeout_run, composite_score: 0.0)

      exhausted_run = create(:agent_run, status: "failed", project: project,
        error_message: "All providers exhausted: claude_code")
      create(:quality_metric, agent_run: exhausted_run, composite_score: 0.0)

      result = described_class.call(project_id: project.id)

      expect(result[:rolling_average]).to eq(0.9)
      expect(result[:sample_size]).to eq(1)
    end
  end

  describe "threshold integration" do
    let(:project) { create(:project) }

    before do
      run = create(:agent_run, project: project)
      create(:quality_metric, agent_run: run, composite_score: 0.8)
    end

    it "includes thresholds when requested" do
      create(:quality_threshold, :project_override, project: project,
        metric_type: "composite_score", goal_type: "create_pr", min_value: 0.5, enabled: true)

      result = described_class.call(
        project_id: project.id,
        include_thresholds: true
      )

      expect(result[:thresholds]).to be_an(Array)
      expect(result[:thresholds].size).to eq(1)
      expect(result[:thresholds].first[:metric_key]).to eq("composite_score")
      expect(result[:thresholds].first[:min_threshold]).to eq(0.5)
    end

    it "excludes thresholds by default" do
      result = described_class.call(project_id: project.id)
      expect(result).not_to have_key(:thresholds)
    end
  end

  describe "gate events integration" do
    let(:project) { create(:project) }

    it "includes gate events when requested" do
      run = create(:agent_run, project: project)
      create(:quality_pause_event, :paused,
        project: project, agent_run: run,
        composite_score: 0.4, threshold: 0.5,
        metadata: { "metric_type" => "composite_score", "goal_type" => "create_pr" })

      result = described_class.call(
        project_id: project.id,
        include_gate_events: true
      )

      expect(result[:gate_events]).to be_an(Array)
      expect(result[:gate_events].size).to eq(1)
      expect(result[:gate_events].first[:event_type]).to eq("trigger")
    end

    it "excludes gate events by default" do
      result = described_class.call(project_id: project.id)
      expect(result).not_to have_key(:gate_events)
    end
  end

  describe "predictive trend" do
    let(:project) { create(:project) }

    it "returns projected scores when enough data exists" do
      scores = [ 0.9, 0.85, 0.8, 0.75, 0.7 ]
      scores.each_with_index do |score, i|
        run = create(:agent_run, project: project)
        metric = create(:quality_metric, agent_run: run, composite_score: score)
        # Ensure ordering by created_at
        metric.update_column(:created_at, i.days.ago)
      end

      result = described_class.call(
        project_id: project.id,
        include_prediction: true
      )

      expect(result[:prediction]).to be_a(Hash)
      expect(result[:prediction][:projected_scores]).to be_an(Array)
      expect(result[:prediction][:projected_scores]).not_to be_empty
      expect(result[:prediction][:slope]).to be_a(Float)
    end

    it "returns empty prediction with insufficient data" do
      run = create(:agent_run, project: project)
      create(:quality_metric, agent_run: run, composite_score: 0.8)

      result = described_class.call(
        project_id: project.id,
        include_prediction: true
      )

      expect(result[:prediction][:projected_scores]).to be_empty
    end

    it "excludes prediction by default" do
      result = described_class.call(project_id: project.id)
      expect(result).not_to have_key(:prediction)
    end

    it "estimates breach when scores are declining" do
      create(:quality_threshold, :project_override, project: project,
        metric_type: "composite_score", goal_type: "create_pr", min_value: 0.5, enabled: true)

      scores = [ 0.9, 0.85, 0.8, 0.75, 0.7 ]
      scores.each_with_index do |score, i|
        run = create(:agent_run, project: project)
        metric = create(:quality_metric, agent_run: run, composite_score: score)
        metric.update_column(:created_at, (scores.size - 1 - i).days.ago)
      end

      result = described_class.call(
        project_id: project.id,
        include_prediction: true
      )

      expect(result[:prediction][:breach_estimate]).to be_a(Integer)
      expect(result[:prediction][:breach_estimate]).to be > 0
    end
  end
end
