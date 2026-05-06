# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::DashboardStats do
  let(:project) { create(:project) }

  describe "#model_comparison" do
    it "groups quality by effective provider" do
      run1 = create(:agent_run, project: project, agent_type: "claude_code")
      run2 = create(:agent_run, :with_custom_prompt, project: project, agent_type: "cursor")
      create(:quality_metric, agent_run: run1, composite_score: 0.9)
      create(:quality_metric, :human, agent_run: run2, composite_score: 0.7)

      result = described_class.call(project: project)

      expect(result[:model_comparison]).to be_an(Array)
      expect(result[:model_comparison].size).to be >= 1
      expect(result[:model_comparison]).to all(include(:provider, :avg_score, :sample_size))
    end

    it "returns empty array when no metrics exist" do
      result = described_class.call(project: project)
      expect(result[:model_comparison]).to eq([])
    end
  end

  describe "#gate_status" do
    it "returns empty gate status when no thresholds configured" do
      create(:quality_threshold, :project_override, :disabled,
        project: project, metric_type: "composite_score", goal_type: "create_pr")

      result = described_class.call(project: project)

      expect(result[:gate_status][:thresholds]).to eq([])
      expect(result[:gate_status][:recent_events]).to eq([])
      expect(result[:gate_status][:active_breaches]).to eq(0)
    end

    it "returns threshold configuration" do
      create(:quality_threshold, :project_override, project: project,
        metric_type: "composite_score", goal_type: "create_pr", min_value: 0.5, enabled: true)

      result = described_class.call(project: project)

      expect(result[:gate_status][:thresholds].size).to eq(1)
      expect(result[:gate_status][:thresholds].first[:metric_key]).to eq("composite_score")
    end

    it "includes recent gate events" do
      run = create(:agent_run, project: project)
      create(:quality_pause_event, :paused,
        project: project, agent_run: run,
        composite_score: 0.4, threshold: 0.5,
        metadata: { "metric_type" => "composite_score", "goal_type" => "create_pr" })

      result = described_class.call(project: project)

      expect(result[:gate_status][:recent_events].size).to eq(1)
      expect(result[:gate_status][:recent_events].first[:event_type]).to eq("trigger")
    end

    it "counts active breaches" do
      create(:quality_threshold, :project_override, project: project,
        metric_type: "composite_score", goal_type: "create_pr", min_value: 0.5, enabled: true)
      3.times do
        run = create(:agent_run, project: project)
        create(:quality_metric, agent_run: run, composite_score: 0.4)
      end

      result = described_class.call(project: project)
      expect(result[:gate_status][:active_breaches]).to eq(1)
    end
  end

  describe "#export_data" do
    it "returns metric records for export" do
      run = create(:agent_run, project: project)
      create(:quality_metric, agent_run: run, composite_score: 0.85)

      stats = described_class.new(project: project)
      data = stats.export_data

      expect(data.size).to eq(1)
      expect(data.first).to include(
        :id, :date, :metric_type, :composite_score, :scores,
        :feedback_source, :agent_run_id, :provider, :goal
      )
    end

    it "returns empty array when no metrics exist" do
      stats = described_class.new(project: project)
      expect(stats.export_data).to eq([])
    end
  end
end
