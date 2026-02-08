# frozen_string_literal: true

require "rails_helper"

RSpec.describe TokenUsageTracker do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }

  describe ".track" do
    it "increments tokens_input on the agent run" do
      expect {
        described_class.track(agent_run: agent_run, tokens_input: 1000, tokens_output: 500)
      }.to change { agent_run.reload.tokens_input }.by(1000)
    end

    it "increments tokens_output on the agent run" do
      expect {
        described_class.track(agent_run: agent_run, tokens_input: 1000, tokens_output: 500)
      }.to change { agent_run.reload.tokens_output }.by(500)
    end

    it "calculates and sets cost_cents on the agent run" do
      described_class.track(agent_run: agent_run, tokens_input: 1_000_000, tokens_output: 1_000_000)

      agent_run.reload
      # $3/M input + $15/M output = $18 = 1800 cents
      expect(agent_run.cost_cents).to eq(1800)
    end

    it "accumulates across multiple calls" do
      described_class.track(agent_run: agent_run, tokens_input: 100, tokens_output: 50)
      described_class.track(agent_run: agent_run, tokens_input: 200, tokens_output: 100)

      agent_run.reload
      expect(agent_run.tokens_input).to eq(300)
      expect(agent_run.tokens_output).to eq(150)
    end

    it "updates project total_tokens_used" do
      expect {
        described_class.track(agent_run: agent_run, tokens_input: 1000, tokens_output: 500)
      }.to change { project.reload.total_tokens_used }.by(1500)
    end

    it "updates project total_cost_cents" do
      expect {
        described_class.track(agent_run: agent_run, tokens_input: 1_000_000, tokens_output: 1_000_000)
      }.to change { project.reload.total_cost_cents }.by(1800)
    end

    it "creates a metric log entry" do
      expect {
        described_class.track(agent_run: agent_run, tokens_input: 1000, tokens_output: 500)
      }.to change { agent_run.agent_run_logs.where(log_type: "metric").count }.by(1)

      log = agent_run.agent_run_logs.where(log_type: "metric").last
      content = JSON.parse(log.content)
      expect(content["tokens_input"]).to eq(1000)
      expect(content["tokens_output"]).to eq(500)
      expect(log.metadata).to eq({ "type" => "token_usage" })
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
