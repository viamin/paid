# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::CompareOutcomes do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    context "with both paid-native and external runs" do
      let!(:paid_run_with_merged_pr) do
        create(:agent_run, :completed, project: project,
               execution_origin: "paid_native", duration_seconds: 100, tokens_input: 500, tokens_output: 200, cost_cents: 50, pull_request_url: "https://github.com/test/pr/1")
      end
      let!(:external_run_with_open_pr) do
        create(:agent_run, :external_execution, :completed, project: project,
               external_source_key: "cursor", duration_seconds: 150, tokens_input: 750, tokens_output: 300, cost_cents: 75, pull_request_url: "https://github.com/test/pr/2")
      end

      before do
        create(:agent_run, :completed, project: project,
               execution_origin: "paid_native", duration_seconds: 200, tokens_input: 1000, tokens_output: 400, cost_cents: 100)
        create(:quality_metric, :human, agent_run: paid_run_with_merged_pr, scores: { "pr_merged" => 1.0 })
        create(:quality_metric, :human, agent_run: external_run_with_open_pr, scores: { "pr_merged" => 0.0 })
      end

      it "returns separate metrics for paid-native and external runs" do
        result = described_class.call(project: project)

        expect(result.paid_native.run_count).to eq(2)
        expect(result.paid_native.success_rate).to eq(1.0)
        expect(result.paid_native.avg_duration_seconds).to eq(150.0)

        expect(result.external.run_count).to eq(1)
        expect(result.external.avg_duration_seconds).to eq(150.0)
      end

      it "uses the recorded pr_merged quality signal for merge rate" do
        result = described_class.call(project: project)

        expect(result.paid_native.pr_merge_rate).to eq(0.5)
        expect(result.external.pr_merge_rate).to eq(0.0)
      end

      it "breaks down external metrics by source" do
        result = described_class.call(project: project)

        expect(result.by_source).to have_key("cursor")
        expect(result.by_source["cursor"].run_count).to eq(1)
      end

      it "averages tokens per run even when input/output nil patterns differ" do
        create(:agent_run, :external_execution, :completed, project: project,
               external_source_key: "devin", tokens_input: 100, tokens_output: nil)
        create(:agent_run, :external_execution, :completed, project: project,
               external_source_key: "devin", tokens_input: 200, tokens_output: 50)

        result = described_class.call(project: project)

        expect(result.by_source["devin"].avg_tokens_used).to eq(175.0)
      end

      it "excludes runs with no token data from token averages" do
        create(:agent_run, :external_execution, :completed, project: project,
               external_source_key: "factory", tokens_input: nil, tokens_output: nil)
        create(:agent_run, :external_execution, :completed, project: project,
               external_source_key: "factory", tokens_input: 80, tokens_output: 20)

        result = described_class.call(project: project)

        expect(result.by_source["factory"].avg_tokens_used).to eq(100.0)
      end

      it "filters comparison windows by execution timestamps instead of ingest time" do
        recent_window_start = 2.days.ago
        recent_window_end = 1.day.ago

        create(:agent_run, :external_execution, :completed, project: project,
               external_source_key: "cursor", created_at: Time.current, started_at: 10.days.ago, completed_at: 10.days.ago + 10.minutes)
        create(:agent_run, :external_execution, :completed, project: project,
               external_source_key: "cursor", created_at: 10.days.ago, started_at: recent_window_start + 1.hour, completed_at: recent_window_start + 2.hours)

        result = described_class.call(project: project, period_start: recent_window_start, period_end: recent_window_end)

        expect(result.external.run_count).to eq(1)
      end
    end

    context "with no runs" do
      it "returns empty metrics" do
        result = described_class.call(project: project)

        expect(result.paid_native.run_count).to eq(0)
        expect(result.paid_native.success_rate).to eq(0.0)
        expect(result.external.run_count).to eq(0)
      end
    end
  end
end
