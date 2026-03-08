# frozen_string_literal: true

require "rails_helper"

RSpec.describe TokenUsages::Aggregate do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }

  before do
    create(:token_usage, agent_run: agent_run, input_tokens: 1000, output_tokens: 500,
           cost_cents: 10, model_name: "claude-3-5-sonnet-20241022", request_type: "agent")
    create(:token_usage, agent_run: agent_run, input_tokens: 2000, output_tokens: 1000,
           cost_cents: 20, model_name: "gpt-4o", request_type: "planning")
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
  end

  describe ".for_project" do
    it "scopes results to a project" do
      other_project = create(:project)
      other_run = create(:agent_run, :running, project: other_project)
      create(:token_usage, agent_run: other_run, cost_cents: 100)

      result = described_class.for_project(project.id)
      expect(result[:total_cost_cents]).to eq(30)
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
