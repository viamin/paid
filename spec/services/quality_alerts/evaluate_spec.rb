# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityAlerts::Evaluate do
  let(:account) { create(:account) }
  let(:project) do
    create(:project, account: account, quality_gate_settings: {
      "enabled" => true,
      "composite_score_threshold" => 0.5,
      "min_recent_runs" => 3,
      "lookback_window_hours" => 24,
      "metric_thresholds" => { "pr_created" => 0.8 }
    })
  end

  describe ".call" do
    context "when quality gates are disabled" do
      before { project.update!(quality_gate_settings: { "enabled" => false }) }

      it "returns a non-breached result with reason" do
        result = described_class.call(project: project)

        expect(result[:breached]).to be false
        expect(result[:reason]).to eq("quality_gates_disabled")
      end
    end

    context "when there is insufficient data" do
      before do
        2.times do
          agent_run = create(:agent_run, project: project)
          create(:quality_metric, agent_run: agent_run, composite_score: 0.3)
        end
      end

      it "returns a non-breached result with reason" do
        result = described_class.call(project: project)

        expect(result[:breached]).to be false
        expect(result[:reason]).to eq("insufficient_data")
        expect(result[:sample_size]).to eq(2)
        expect(result[:min_required]).to eq(3)
      end
    end

    context "when metrics are above thresholds" do
      before do
        3.times do
          agent_run = create(:agent_run, project: project)
          create(:quality_metric, agent_run: agent_run, composite_score: 0.8,
            scores: { "pr_created" => 1.0, "ci_passed" => 1.0 })
        end
      end

      it "returns a non-breached result" do
        result = described_class.call(project: project)

        expect(result[:breached]).to be false
        expect(result[:breaches]).to be_empty
      end
    end

    context "when composite score is below threshold" do
      before do
        3.times do
          agent_run = create(:agent_run, project: project)
          create(:quality_metric, agent_run: agent_run, composite_score: 0.3,
            scores: { "pr_created" => 1.0, "ci_passed" => 0.0 })
        end
      end

      it "returns a breached result with composite score breach" do
        result = described_class.call(project: project)

        expect(result[:breached]).to be true
        expect(result[:breaches].size).to be >= 1

        composite_breach = result[:breaches].find { |b| b[:metric] == "composite_score" }
        expect(composite_breach).to be_present
        expect(composite_breach[:current]).to be < 0.5
        expect(composite_breach[:threshold]).to eq(0.5)
      end

      it "includes recent run summaries" do
        result = described_class.call(project: project)

        expect(result[:recent_runs]).to be_present
        expect(result[:recent_runs].first).to include(:agent_run_id, :composite_score, :scores, :created_at)
      end

      it "includes remediation actions" do
        result = described_class.call(project: project)

        expect(result[:remediation_actions]).to be_present
        expect(result[:remediation_actions]).to include("Review recent agent runs for overall quality regression")
      end
    end

    context "when individual metric thresholds are breached" do
      before do
        3.times do
          agent_run = create(:agent_run, project: project)
          create(:quality_metric, agent_run: agent_run, composite_score: 0.9,
            scores: { "pr_created" => 0.5, "ci_passed" => 1.0 })
        end
      end

      it "detects metric-specific breaches" do
        result = described_class.call(project: project)

        expect(result[:breached]).to be true
        pr_breach = result[:breaches].find { |b| b[:metric] == "pr_created" }
        expect(pr_breach).to be_present
        expect(pr_breach[:current]).to eq(0.5)
        expect(pr_breach[:threshold]).to eq(0.8)
      end
    end

    context "when metrics are outside the lookback window" do
      before do
        3.times do
          agent_run = create(:agent_run, project: project)
          create(:quality_metric, agent_run: agent_run, composite_score: 0.3,
            scores: { "pr_created" => 0.0 }, created_at: 48.hours.ago)
        end
      end

      it "returns insufficient data since old metrics are excluded" do
        result = described_class.call(project: project)

        expect(result[:breached]).to be false
        expect(result[:reason]).to eq("insufficient_data")
      end
    end
  end
end
