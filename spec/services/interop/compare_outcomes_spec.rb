# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::CompareOutcomes do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    context "with both paid-native and external runs" do
      before do
        create(:agent_run, :completed, project: project,
               execution_origin: "paid_native", duration_seconds: 100, tokens_input: 500, tokens_output: 200, cost_cents: 50, pull_request_url: "https://github.com/test/pr/1")
        create(:agent_run, :completed, project: project,
               execution_origin: "paid_native", duration_seconds: 200, tokens_input: 1000, tokens_output: 400, cost_cents: 100)
        create(:agent_run, :external_execution, :completed, project: project,
               external_source_key: "cursor", duration_seconds: 150, tokens_input: 750, tokens_output: 300, cost_cents: 75, pull_request_url: "https://github.com/test/pr/2")
      end

      it "returns separate metrics for paid-native and external runs" do
        result = described_class.call(project: project)

        expect(result.paid_native.run_count).to eq(2)
        expect(result.paid_native.success_rate).to eq(1.0)
        expect(result.paid_native.avg_duration_seconds).to eq(150.0)

        expect(result.external.run_count).to eq(1)
        expect(result.external.avg_duration_seconds).to eq(150.0)
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
