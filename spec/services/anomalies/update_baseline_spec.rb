# frozen_string_literal: true

require "rails_helper"

RSpec.describe Anomalies::UpdateBaseline do
  let(:project) { create(:project) }

  describe ".call" do
    context "with fewer than MIN_SAMPLE_SIZE completed runs" do
      before do
        create_list(:agent_run, 4, :completed, :with_metrics, project: project)
      end

      it "does not create baselines" do
        expect { described_class.call(project) }.not_to change(ProjectBaseline, :count)
      end
    end

    context "with enough completed runs" do
      before do
        6.times do |i|
          create(:agent_run, :completed,
            project: project,
            tokens_input: 5000 + (i * 1000),
            tokens_output: 2500 + (i * 500),
            duration_seconds: 300 + (i * 60),
            iterations: 3 + i,
            cost_cents: 100 + (i * 20))
        end
      end

      it "creates baselines for all metric types" do
        described_class.call(project)
        expect(project.project_baselines.count).to eq(4)
        expect(project.project_baselines.pluck(:metric_name).sort).to eq(
          ProjectBaseline::METRIC_NAMES.sort
        )
      end

      it "calculates correct mean for tokens_total" do
        described_class.call(project)
        baseline = project.project_baselines.find_by(metric_name: "tokens_total")
        # tokens: (5000+2500), (6000+3000), (7000+3500), (8000+4000), (9000+4500), (10000+5000)
        # = 7500, 9000, 10500, 12000, 13500, 15000
        # mean = 11250
        expect(baseline.mean).to be_within(0.1).of(11250.0)
      end

      it "calculates correct standard deviation" do
        described_class.call(project)
        baseline = project.project_baselines.find_by(metric_name: "tokens_total")
        expect(baseline.standard_deviation).to be > 0
      end

      it "updates existing baselines" do
        described_class.call(project)
        initial_count = ProjectBaseline.count

        create(:agent_run, :completed,
          project: project,
          tokens_input: 50_000,
          tokens_output: 25_000,
          duration_seconds: 3000,
          iterations: 50,
          cost_cents: 500)

        described_class.call(project)
        expect(ProjectBaseline.count).to eq(initial_count)
      end

      it "sets sample_count" do
        described_class.call(project)
        baseline = project.project_baselines.find_by(metric_name: "tokens_total")
        expect(baseline.sample_count).to eq(6)
      end

      it "sets p95" do
        described_class.call(project)
        baseline = project.project_baselines.find_by(metric_name: "tokens_total")
        expect(baseline.p95).to be > baseline.mean
      end
    end

    context "with old runs outside lookback window" do
      before do
        # 4 recent + 2 old = 6 total, but only 4 in window
        4.times do
          create(:agent_run, :completed, :with_metrics, project: project)
        end
        2.times do
          create(:agent_run, :completed, :with_metrics, project: project, completed_at: 91.days.ago)
        end
      end

      it "ignores runs outside the lookback window" do
        expect { described_class.call(project) }.not_to change(ProjectBaseline, :count)
      end
    end
  end
end
