# frozen_string_literal: true

require "rails_helper"

RSpec.describe TokenUsageTracker do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }

  describe ".track" do
    it "increments tokens_input on the agent run" do
      expect {
        described_class.track(agent_run: agent_run, usage: { tokens_input: 1000, tokens_output: 500 })
      }.to change { agent_run.reload.tokens_input }.by(1000)
    end

    it "increments tokens_output on the agent run" do
      expect {
        described_class.track(agent_run: agent_run, usage: { tokens_input: 1000, tokens_output: 500 })
      }.to change { agent_run.reload.tokens_output }.by(500)
    end

    it "calculates and sets cost_cents on the agent run" do
      described_class.track(agent_run: agent_run, usage: { tokens_input: 1_000_000, tokens_output: 1_000_000 })

      agent_run.reload
      # $3/M input + $15/M output = $18 = 1800 cents
      expect(agent_run.cost_cents).to eq(1800)
    end

    it "accumulates across multiple calls" do
      described_class.track(agent_run: agent_run, usage: { tokens_input: 100, tokens_output: 50 })
      described_class.track(agent_run: agent_run, usage: { tokens_input: 200, tokens_output: 100 })

      agent_run.reload
      expect(agent_run.tokens_input).to eq(300)
      expect(agent_run.tokens_output).to eq(150)
    end

    it "updates project total_tokens_used" do
      expect {
        described_class.track(agent_run: agent_run, usage: { tokens_input: 1000, tokens_output: 500 })
      }.to change { project.reload.total_tokens_used }.by(1500)
    end

    it "updates project total_cost_cents" do
      expect {
        described_class.track(agent_run: agent_run, usage: { tokens_input: 1_000_000, tokens_output: 1_000_000 })
      }.to change { project.reload.total_cost_cents }.by(1800)
    end

    it "creates a metric log entry" do
      expect {
        described_class.track(agent_run: agent_run, usage: { tokens_input: 1000, tokens_output: 500 })
      }.to change { agent_run.agent_run_logs.where(log_type: "metric").count }.by(1)

      log = agent_run.agent_run_logs.where(log_type: "metric").last
      content = JSON.parse(log.content)
      expect(content["tokens_input"]).to eq(1000)
      expect(content["tokens_output"]).to eq(500)
      expect(log.metadata).to eq({ "type" => "token_usage" })
    end

    it "creates a per-request TokenUsage record" do
      expect {
        described_class.track(
          agent_run: agent_run,
          usage: {
            tokens_input: 1000,
            tokens_output: 500,
            llm_model: "claude-3-5-sonnet-20241022",
            request_type: "agent"
          }
        )
      }.to change(TokenUsage, :count).by(1)

      usage = TokenUsage.last
      expect(usage.agent_run).to eq(agent_run)
      expect(usage.input_tokens).to eq(1000)
      expect(usage.output_tokens).to eq(500)
      expect(usage.llm_model).to eq("claude-3-5-sonnet-20241022")
      expect(usage.request_type).to eq("agent")
    end

    it "updates cost budgets for the project" do
      budget = create(:cost_budget, project: project, limit_cents: 100_000, period_started_at: Time.current.beginning_of_month)

      described_class.track(agent_run: agent_run, usage: { tokens_input: 1_000_000, tokens_output: 1_000_000 })

      expect(budget.reload.current_usage_cents).to eq(1800)
    end

    it "includes llm_model and request_type in the log entry" do
      described_class.track(
        agent_run: agent_run,
        usage: {
          tokens_input: 1000,
          tokens_output: 500,
          llm_model: "claude-3-5-sonnet-20241022",
          request_type: "planning"
        }
      )

      log = agent_run.agent_run_logs.where(log_type: "metric").last
      content = JSON.parse(log.content)
      expect(content["llm_model"]).to eq("claude-3-5-sonnet-20241022")
      expect(content["request_type"]).to eq("planning")
    end

    context "when update_aggregates is false" do
      it "creates a TokenUsage record without updating agent_run or project counters" do
        expect {
          described_class.track(
            agent_run: agent_run,
            usage: { tokens_input: 1000, tokens_output: 500, request_type: "run_summary" },
            update_aggregates: false
          )
        }.to change(TokenUsage, :count).by(1)

        expect(agent_run.reload.tokens_input).to eq(0)
        expect(project.reload.total_tokens_used).to eq(0)
      end

      it "does not update cost budgets" do
        budget = create(:cost_budget, project: project, limit_cents: 100_000, period_started_at: Time.current.beginning_of_month)

        described_class.track(
          agent_run: agent_run,
          usage: { tokens_input: 1_000_000, tokens_output: 1_000_000, request_type: "run_summary" },
          update_aggregates: false
        )

        expect(budget.reload.current_usage_cents).to eq(0)
      end
    end
  end

  describe ".update_aggregates" do
    it "updates agent_run, project, and budget counters without creating a TokenUsage record" do
      budget = create(:cost_budget, project: project, limit_cents: 100_000, period_started_at: Time.current.beginning_of_month)

      expect {
        described_class.update_aggregates(agent_run: agent_run, tokens_input: 1000, tokens_output: 500)
      }.not_to change(TokenUsage, :count)

      agent_run.reload
      expect(agent_run.tokens_input).to eq(1000)
      expect(agent_run.tokens_output).to eq(500)
      expect(agent_run.cost_cents).to eq(1) # ~1.05 cents rounded
      expect(project.reload.total_tokens_used).to eq(1500)
      expect(budget.reload.current_usage_cents).to eq(1)
    end
  end

  describe ".calculate_cost" do
    it "returns 0 for zero tokens" do
      expect(described_class.calculate_cost(0, 0)).to eq(0)
    end

    it "calculates cost based on default pricing" do
      # $3/M input, $15/M output
      # 1M input = $3 = 300 cents
      # 1M output = $15 = 1500 cents
      expect(described_class.calculate_cost(1_000_000, 1_000_000)).to eq(1800)
    end

    it "handles small token counts" do
      # 1000 input = $0.003 = 0.3 cents
      # 500 output = $0.0075 = 0.75 cents
      # Total = $0.0105 => 1.05 cents, rounded = 1
      expect(described_class.calculate_cost(1000, 500)).to eq(1)
    end

    it "handles large token counts" do
      # 10M input = $30 = 3000 cents
      # 5M output = $75 = 7500 cents
      expect(described_class.calculate_cost(10_000_000, 5_000_000)).to eq(10_500)
    end
  end
end
