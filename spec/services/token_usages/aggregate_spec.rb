# frozen_string_literal: true

require "rails_helper"

RSpec.describe TokenUsages::Aggregate do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }

  before do
    create(:token_usage, agent_run: agent_run, input_tokens: 1000, output_tokens: 500,
           cost_cents: 10, llm_model: "claude-3-5-sonnet-20241022", request_type: "agent")
    create(:token_usage, agent_run: agent_run, input_tokens: 2000, output_tokens: 1000,
           cost_cents: 20, llm_model: "gpt-4o", request_type: "planning")
  end

  describe ".call" do
    it "returns aggregated usage data" do
      result = described_class.call

      expect(result[:total_cost_cents]).to eq(30)
      expect(result[:total_input_tokens]).to eq(3000)
      expect(result[:total_output_tokens]).to eq(1500)
      expect(result[:cost_by_model]).to include("claude-3-5-sonnet-20241022" => 10, "gpt-4o" => 20)
      expect(result[:cost_by_request_type]).to include("agent" => 10, "planning" => 20)
    end

    it "includes run_delta records without double-counting run_summary audit totals" do
      kilocode_run = create(:agent_run, :kilocode, :running, project: project)
      create(:token_usage, agent_run: kilocode_run, request_type: "run_summary",
             input_tokens: 4000, output_tokens: 1500, cost_cents: 26,
             llm_model: "anthropic/claude-sonnet-4.5")
      create(:token_usage, agent_run: kilocode_run, request_type: "agent",
             input_tokens: 1000, output_tokens: 500, cost_cents: 7,
             llm_model: "anthropic/claude-sonnet-4.5")
      create(:token_usage, agent_run: kilocode_run, request_type: "run_delta",
             input_tokens: 3000, output_tokens: 1000, cost_cents: 19,
             llm_model: "anthropic/claude-sonnet-4.5")

      result = described_class.call

      aggregate_failures do
        expect(result[:total_cost_cents]).to eq(56)
        expect(result[:total_input_tokens]).to eq(7000)
        expect(result[:total_output_tokens]).to eq(3000)
        expect(result[:cost_by_model]).to include("anthropic/claude-sonnet-4.5" => 26)
        expect(result[:cost_by_request_type]).to include("agent" => 17, "planning" => 20, "run_delta" => 19)
        expect(result[:cost_by_request_type]).not_to include("run_summary")
      end
    end
  end

  describe ".for_project" do
    it "scopes results to a project" do
      other_project = create(:project)
      other_run = create(:agent_run, :running, project: other_project)
      create(:token_usage, agent_run: other_run, cost_cents: 100)

      result = described_class.for_project(project.id)
      expect(result[:total_cost_cents]).to eq(30)
    end

    it "includes knowledge-run token usage" do
      knowledge_run = create(:knowledge_run, :running, project: project)
      create(:token_usage, :knowledge, knowledge_run: knowledge_run, cost_cents: 40, input_tokens: 400, output_tokens: 0)

      result = described_class.for_project(project.id)
      expect(result[:total_cost_cents]).to eq(70)
      expect(result[:total_input_tokens]).to eq(3400)
    end
  end

  describe "#project_cost_projection" do
    it "projects future costs based on recent usage" do
      aggregator = described_class.new(scope: TokenUsage.by_project(project.id))
      result = aggregator.project_cost_projection(days_ahead: 30)

      expect(result[:daily_average_cents]).to be_a(Integer)
      expect(result[:projected_cost_cents]).to be_a(Integer)
    end
  end
end
