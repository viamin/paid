# frozen_string_literal: true

require "rails_helper"

RSpec.describe Anomalies::Detect do
  let(:project) { create(:project) }

  describe ".call" do
    context "without enough historical data for baselines" do
      let(:agent_run) { create(:agent_run, :completed, :with_metrics, project: project) }

      it "returns empty array" do
        expect(described_class.call(agent_run)).to eq([])
      end
    end

    context "with established baselines" do
      before do
        # Create baseline runs with natural variation
        [ 14_000, 15_000, 15_500, 16_000, 14_500, 15_000 ].each_with_index do |tokens, i|
          create(:agent_run, :completed,
            project: project,
            tokens_input: tokens * 2 / 3,
            tokens_output: tokens / 3,
            duration_seconds: 550 + (i * 20),
            iterations: 4 + (i % 3),
            cost_cents: 140 + (i * 5))
        end
      end

      context "when run is within normal range" do
        let(:normal_run) do
          create(:agent_run, :completed,
            project: project,
            tokens_input: 10_500,
            tokens_output: 5_000,
            duration_seconds: 620,
            iterations: 5,
            cost_cents: 155)
        end

        it "returns no anomalies" do
          expect(described_class.call(normal_run)).to be_empty
        end
      end

      context "when run has abnormally high token usage" do
        let(:anomalous_run) do
          create(:agent_run, :completed,
            project: project,
            tokens_input: 200_000,
            tokens_output: 100_000,
            duration_seconds: 600,
            iterations: 5,
            cost_cents: 150)
        end

        it "detects token anomaly" do
          anomalies = described_class.call(anomalous_run)
          token_anomaly = anomalies.find { |a| a.metric_name == "tokens_total" }
          expect(token_anomaly).to be_present
          expect(token_anomaly.anomaly_type).to eq("high_value")
        end

        it "persists the anomaly" do
          expect { described_class.call(anomalous_run) }
            .to change(AgentRunAnomaly, :count).by_at_least(1)
        end

        it "logs the anomaly" do
          allow(Rails.logger).to receive(:warn)
          described_class.call(anomalous_run)

          expect(Rails.logger).to have_received(:warn).with(
            hash_including(
              message: "anomaly_detection.anomaly_detected",
              metric_name: "tokens_total"
            )
          )
        end
      end

      context "when run has abnormally high cost" do
        let(:expensive_run) do
          create(:agent_run, :completed,
            project: project,
            tokens_input: 10_000,
            tokens_output: 5_000,
            duration_seconds: 600,
            iterations: 5,
            cost_cents: 100_000)
        end

        it "detects cost anomaly" do
          anomalies = described_class.call(expensive_run)
          cost_anomaly = anomalies.find { |a| a.metric_name == "cost_cents" }
          expect(cost_anomaly).to be_present
          expect(cost_anomaly.severity).to be_in(%w[warning critical])
        end
      end

      context "with varied baseline data" do
        before do
          create(:agent_run, :completed,
            project: project,
            tokens_input: 5_000,
            tokens_output: 2_000,
            duration_seconds: 300,
            iterations: 2,
            cost_cents: 75)
          create(:agent_run, :completed,
            project: project,
            tokens_input: 20_000,
            tokens_output: 10_000,
            duration_seconds: 900,
            iterations: 8,
            cost_cents: 225)
        end

        let(:high_duration_run) do
          create(:agent_run, :completed,
            project: project,
            tokens_input: 10_000,
            tokens_output: 5_000,
            duration_seconds: 5000,
            iterations: 5,
            cost_cents: 150)
        end

        it "detects duration anomaly" do
          anomalies = described_class.call(high_duration_run)
          duration_anomaly = anomalies.find { |a| a.metric_name == "duration_seconds" }
          expect(duration_anomaly).to be_present
          expect(duration_anomaly.anomaly_type).to eq("high_value")
        end
      end
    end

    context "with severity classification" do
      before do
        # Create runs with meaningful variation for stddev
        [ 10_000, 12_000, 14_000, 16_000, 18_000, 20_000 ].each do |tokens|
          create(:agent_run, :completed,
            project: project,
            tokens_input: tokens,
            tokens_output: tokens / 2,
            duration_seconds: 600,
            iterations: 5,
            cost_cents: 150)
        end
      end

      it "classifies extreme deviation as critical" do
        # Use very extreme values so against the historical baseline
        # (which excludes this run), the deviation is still >= 3.0
        extreme_run = create(:agent_run, :completed,
          project: project,
          tokens_input: 5_000_000,
          tokens_output: 2_500_000,
          duration_seconds: 600,
          iterations: 5,
          cost_cents: 150)

        anomalies = described_class.call(extreme_run)
        token_anomaly = anomalies.find { |a| a.metric_name == "tokens_total" }
        expect(token_anomaly).to be_present
        expect(token_anomaly.severity).to eq("critical")
        expect(token_anomaly.deviation_factor).to be >= described_class::CRITICAL_THRESHOLD
      end
    end

    context "with partial baseline set (fewer than all metrics)" do
      before do
        # Only create baselines for two metrics, simulating metrics that never
        # reach MIN_SAMPLE_SIZE. Baselines are fresh.
        %w[tokens_total duration_seconds].each do |metric_name|
          create(:project_baseline,
            project: project,
            metric_name: metric_name,
            last_calculated_at: 1.hour.ago)
        end
      end

      it "does not force a baseline refresh on every detection" do
        agent_run = create(:agent_run, :completed,
          project: project,
          tokens_input: 10_000,
          tokens_output: 5_000,
          duration_seconds: 600,
          iterations: 5,
          cost_cents: 150)

        expect(Anomalies::UpdateBaseline).not_to receive(:call)
        described_class.call(agent_run)
      end
    end

    context "with stale baselines" do
      let(:stale_baseline) do
        create(:project_baseline,
          project: project,
          metric_name: "tokens_total",
          last_calculated_at: 2.days.ago)
      end

      before do
        stale_baseline

        %w[duration_seconds iterations cost_cents].each do |metric_name|
          create(:project_baseline, project: project, metric_name: metric_name, last_calculated_at: 2.days.ago)
        end

        [ 14_000, 15_000, 15_500, 16_000, 14_500, 15_000 ].each_with_index do |tokens, i|
          create(:agent_run, :completed,
            project: project,
            tokens_input: tokens * 2 / 3,
            tokens_output: tokens / 3,
            duration_seconds: 550 + (i * 20),
            iterations: 4 + (i % 3),
            cost_cents: 140 + (i * 5))
        end
      end

      it "refreshes baselines before detecting anomalies" do
        agent_run = create(:agent_run, :completed,
          project: project,
          tokens_input: 10_500,
          tokens_output: 5_000,
          duration_seconds: 620,
          iterations: 5,
          cost_cents: 155)

        expect { described_class.call(agent_run) }
          .to change { stale_baseline.reload.last_calculated_at }
      end

      it "skips detection when stale baselines cannot be refreshed" do
        project.project_baselines.delete_all
        project.agent_runs.delete_all

        create(:project_baseline,
          project: project,
          metric_name: "tokens_total",
          mean: 1_000,
          standard_deviation: 10,
          sample_count: 6,
          p95: 1_100,
          last_calculated_at: 2.days.ago)

        4.times { |i| create(:agent_run, :completed, project: project,
          tokens_input: 1_000 + i, tokens_output: 500 + i, completed_at: 1.day.ago) }

        agent_run = create(:agent_run, :completed,
          project: project,
          tokens_input: 50_000,
          tokens_output: 25_000,
          completed_at: Time.current)

        expect(described_class.call(agent_run)).to be_empty
        expect(AgentRunAnomaly.where(agent_run: agent_run)).to be_empty
      end
    end

    context "when tokens are nil" do
      before do
        [ 14_000, 15_000, 15_500, 16_000, 14_500, 15_000 ].each_with_index do |tokens, i|
          create(:agent_run, :completed,
            project: project,
            tokens_input: tokens * 2 / 3,
            tokens_output: tokens / 3,
            duration_seconds: 550 + (i * 20),
            iterations: 4 + (i % 3),
            cost_cents: 140 + (i * 5))
        end
      end

      it "skips tokens_total detection when both token fields are nil" do
        run_without_tokens = create(:agent_run, :completed,
          project: project,
          tokens_input: nil,
          tokens_output: nil,
          duration_seconds: 600,
          iterations: 5,
          cost_cents: 150)

        anomalies = described_class.call(run_without_tokens)
        expect(anomalies.map(&:metric_name)).not_to include("tokens_total")
      end

      it "detects tokens_total when only one token field is present" do
        run_with_partial_tokens = create(:agent_run, :completed,
          project: project,
          tokens_input: 500_000,
          tokens_output: nil,
          duration_seconds: 600,
          iterations: 5,
          cost_cents: 150)

        anomalies = described_class.call(run_with_partial_tokens)
        token_anomaly = anomalies.find { |a| a.metric_name == "tokens_total" }
        expect(token_anomaly).to be_present
      end
    end

    context "when persisting an anomaly races on the unique index" do
      before do
        [ 14_000, 15_000, 15_500, 16_000, 14_500, 15_000 ].each_with_index do |tokens, i|
          create(:agent_run, :completed,
            project: project,
            tokens_input: tokens * 2 / 3,
            tokens_output: tokens / 3,
            duration_seconds: 550 + (i * 20),
            iterations: 4 + (i % 3),
            cost_cents: 140 + (i * 5))
        end
      end

      it "refetches and updates the existing anomaly" do
        agent_run = create(:agent_run, :completed,
          project: project,
          tokens_input: 200_000,
          tokens_output: 100_000,
          duration_seconds: 600,
          iterations: 5,
          cost_cents: 150)
        existing_anomaly = create(:agent_run_anomaly, agent_run: agent_run, project: project, metric_name: "tokens_total")

        allow(AgentRunAnomaly).to receive(:find_or_initialize_by).and_call_original
        allow(AgentRunAnomaly).to receive(:find_or_initialize_by)
          .with(agent_run: agent_run, metric_name: "tokens_total")
          .and_raise(ActiveRecord::RecordNotUnique)

        expect { described_class.call(agent_run) }.not_to raise_error
        expect(existing_anomaly.reload.metric_value).to eq(300_000.0)
      end
    end

    context "when a baseline has zero standard deviation" do
      before do
        create(:project_baseline,
          project: project,
          metric_name: "tokens_total",
          mean: 15_000,
          standard_deviation: 0,
          sample_count: 6,
          p95: 15_000,
          last_calculated_at: 1.hour.ago)
      end

      it "detects an anomaly when the current value differs from the baseline mean" do
        agent_run = create(:agent_run, :completed,
          project: project,
          tokens_input: 20_000,
          tokens_output: 0)

        anomaly = described_class.call(agent_run).find { |record| record.metric_name == "tokens_total" }

        expect(anomaly).to be_present
        expect(anomaly.severity).to eq("critical")
        expect(anomaly.anomaly_type).to eq("high_value")
      end

      it "skips anomaly creation when the current value matches the baseline mean" do
        agent_run = create(:agent_run, :completed,
          project: project,
          tokens_input: 10_000,
          tokens_output: 5_000)

        expect(described_class.call(agent_run)).to be_empty
      end
    end
  end
end
