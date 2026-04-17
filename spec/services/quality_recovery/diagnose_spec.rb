# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityRecovery::Diagnose do
  describe ".call" do
    let(:project) { create(:project) }

    context "with insufficient data" do
      it "returns empty diagnosis when fewer than minimum runs" do
        create_list(:agent_run, 3, :completed, project: project)

        result = described_class.call(project: project)

        expect(result[:severity]).to eq("none")
        expect(result[:patterns]).to be_empty
        expect(result[:sample_size]).to eq(0)
      end
    end

    context "with high failure rate" do
      it "detects warning-level failure rate" do
        create_list(:agent_run, 4, :completed, project: project)
        create_list(:agent_run, 3, :failed, project: project)

        result = described_class.call(project: project)

        failure_pattern = result[:patterns].find { |p| p[:type] == "high_failure_rate" }
        expect(failure_pattern).to be_present
        expect(failure_pattern[:severity]).to eq("warning")
      end

      it "detects critical failure rate" do
        create_list(:agent_run, 3, :completed, project: project)
        create_list(:agent_run, 5, :failed, project: project)

        result = described_class.call(project: project)

        failure_pattern = result[:patterns].find { |p| p[:type] == "high_failure_rate" }
        expect(failure_pattern).to be_present
        expect(failure_pattern[:severity]).to eq("critical")
      end

      it "includes failure status breakdown" do
        create_list(:agent_run, 3, :completed, project: project)
        create_list(:agent_run, 3, :failed, project: project)
        create_list(:agent_run, 2, project: project, status: "timeout", started_at: 10.minutes.ago, completed_at: Time.current, duration_seconds: 600)

        result = described_class.call(project: project)

        failure_pattern = result[:patterns].find { |p| p[:type] == "high_failure_rate" }
        expect(failure_pattern[:details][:statuses]).to include("failed" => 3, "timeout" => 2)
      end
    end

    context "with quality score decline" do
      it "detects quality drop between recent and older runs" do
        # Older runs with high quality
        older_runs = create_list(:agent_run, 5, :completed, project: project, completed_at: 2.days.ago)
        older_runs.each do |run|
          create(:quality_metric, agent_run: run, composite_score: 0.9)
        end

        # Recent runs with low quality
        recent_runs = create_list(:agent_run, 5, :completed, project: project, completed_at: 1.hour.ago)
        recent_runs.each do |run|
          create(:quality_metric, agent_run: run, composite_score: 0.5)
        end

        result = described_class.call(project: project, window: 10)

        decline_pattern = result[:patterns].find { |p| p[:type] == "quality_score_decline" }
        expect(decline_pattern).to be_present
        expect(decline_pattern[:details][:drop]).to be > 0.15
      end
    end

    context "with anomaly clusters" do
      it "detects clusters of anomalies in the same metric" do
        create_list(:agent_run, 5, :completed, project: project)
        run1 = create(:agent_run, :completed, :with_metrics, project: project)
        run2 = create(:agent_run, :completed, :with_metrics, project: project)

        create(:agent_run_anomaly, agent_run: run1, anomaly_project: project, metric_name: "tokens_total", severity: "warning")
        create(:agent_run_anomaly, agent_run: run2, anomaly_project: project, metric_name: "tokens_total", severity: "critical")

        result = described_class.call(project: project)

        cluster_pattern = result[:patterns].find { |p| p[:type] == "anomaly_cluster" }
        expect(cluster_pattern).to be_present
        expect(cluster_pattern[:details][:anomaly_count]).to eq(2)
      end
    end

    context "with severity assessment" do
      it "returns critical when any pattern is critical" do
        create_list(:agent_run, 2, :completed, project: project)
        create_list(:agent_run, 6, :failed, project: project)

        result = described_class.call(project: project)

        expect(result[:severity]).to eq("critical")
      end

      it "returns none when no patterns are detected" do
        create_list(:agent_run, 6, :completed, project: project)

        result = described_class.call(project: project)

        expect(result[:severity]).to eq("none")
      end
    end
  end
end
