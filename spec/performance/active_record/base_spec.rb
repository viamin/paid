# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveRecord::Base do
  describe "dashboard aggregates" do
    it "loads run volume and cost cards with fixed query counts" do
      account = create(:account)
      project = create(:project, account: account)
      create_list(:agent_run, 3, :completed, project: project, cost_cents: 10, tokens_input: 100, tokens_output: 50)
      create(:agent_run, :running, project: project)

      query_count = count_queries do
        Dashboard::Stats.call(account: account, only: %i[run_volume cost_and_tokens])
      end

      expect(query_count).to be <= 4
    end
  end

  describe "token usage aggregation" do
    it "aggregates totals and grouped costs in two queries" do
      project = create(:project)
      run = create(:agent_run, :running, project: project)
      create(:token_usage, agent_run: run, llm_model: "claude", request_type: "agent", cost_cents: 10)
      create(:token_usage, agent_run: run, llm_model: "claude", request_type: "planning", cost_cents: 5)
      create(:token_usage, agent_run: run, llm_model: "gpt-4o", request_type: "agent", cost_cents: 7)

      query_count = count_queries do
        TokenUsages::Aggregate.call
      end

      expect(query_count).to eq(2)
    end
  end

  describe "knowledge exact search" do
    it "avoids the pre-search existence query" do
      project = create(:project)
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, project_version: project_version)
      artifact = create(:knowledge_artifact,
        project: project,
        collector_run: collector_run,
        identifier: "POST /api/users")
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project)

      queries = capture_queries do
        Knowledge::Search::Exact.call(project: project, query: "POST /api/users")
      end

      expect(queries.grep(/SELECT 1 AS one/i)).to be_empty
      expect(queries.size).to be <= 6
    end
  end
end
