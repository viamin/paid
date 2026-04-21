# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::AggregateTenantUsage do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }
  let(:agent_run) { create(:agent_run, :running, project: project) }

  let(:starts_at) { 1.month.ago }
  let(:ends_at) { Time.current }

  before do
    create(:token_usage, agent_run: agent_run, input_tokens: 1000, output_tokens: 500,
           cost_cents: 10, llm_model: "claude-sonnet-4.5", request_type: "agent")
    create(:token_usage, agent_run: agent_run, input_tokens: 2000, output_tokens: 1000,
           cost_cents: 20, llm_model: "gpt-4o", request_type: "planning")
  end

  describe ".call" do
    it "returns aggregated usage for the account" do
      result = described_class.call(account: account, starts_at: starts_at, ends_at: ends_at)

      expect(result[:account_id]).to eq(account.id)
      expect(result.dig(:token_usage, :total_cost_cents)).to eq(30)
      expect(result.dig(:token_usage, :total_input_tokens)).to eq(3000)
      expect(result.dig(:token_usage, :total_output_tokens)).to eq(1500)
    end

    it "breaks down costs by model" do
      result = described_class.call(account: account, starts_at: starts_at, ends_at: ends_at)

      expect(result.dig(:token_usage, :by_model)).to include(
        "claude-sonnet-4.5" => 10,
        "gpt-4o" => 20
      )
    end

    it "aggregates run counts" do
      result = described_class.call(account: account, starts_at: starts_at, ends_at: ends_at)

      expect(result.dig(:run_usage, :total_runs)).to eq(1)
    end

    it "counts active projects" do
      result = described_class.call(account: account, starts_at: starts_at, ends_at: ends_at)

      expect(result[:project_count]).to eq(1)
    end

    it "returns zero token usage for accounts without projects" do
      empty_account = create(:account)

      result = described_class.call(account: empty_account, starts_at: starts_at, ends_at: ends_at)

      expect(result.dig(:token_usage, :total_cost_cents)).to eq(0)
      expect(result[:cost_by_project]).to be_empty
    end

    it "excludes usage from other accounts" do
      other_account = create(:account)
      other_token = create(:github_token, account: other_account)
      other_project = create(:project, account: other_account, github_token: other_token)
      other_run = create(:agent_run, :running, project: other_project)
      create(:token_usage, agent_run: other_run, cost_cents: 100)

      result = described_class.call(account: account, starts_at: starts_at, ends_at: ends_at)

      expect(result.dig(:token_usage, :total_cost_cents)).to eq(30)
    end

    it "includes knowledge run costs in token usage aggregates" do
      knowledge_run = create(:knowledge_run, :running, project: project)
      create(:token_usage, :knowledge, knowledge_run: knowledge_run, input_tokens: 400,
             output_tokens: 50, cost_cents: 40, llm_model: "gpt-4o-mini")

      result = described_class.call(account: account, starts_at: starts_at, ends_at: ends_at)

      expect(result.dig(:token_usage, :total_cost_cents)).to eq(70)
      expect(result.dig(:token_usage, :total_input_tokens)).to eq(3400)
      expect(result.dig(:token_usage, :total_output_tokens)).to eq(1550)
      expect(result.dig(:token_usage, :by_model)).to include("gpt-4o-mini" => 40)
      expect(result.dig(:token_usage, :by_request_type)).to include("knowledge" => 40)
      expect(result[:cost_by_project]).to include(project.id => 70)
    end

    it "respects time boundaries" do
      old_run = create(:agent_run, :completed, project: project, created_at: 2.months.ago)
      create(:token_usage, agent_run: old_run, cost_cents: 999, created_at: 2.months.ago)

      result = described_class.call(account: account, starts_at: starts_at, ends_at: ends_at)

      expect(result.dig(:token_usage, :total_cost_cents)).to eq(30)
    end
  end
end
