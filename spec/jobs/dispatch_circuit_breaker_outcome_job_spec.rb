# frozen_string_literal: true

require "rails_helper"

RSpec.describe DispatchCircuitBreakerOutcomeJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, :completed, project: project) }

  describe "#perform" do
    it "forwards the outcome to the dispatch circuit breaker service" do
      allow(AgentRuns::DispatchCircuitBreaker).to receive(:record_outcome!)

      described_class.perform_now(
        account_id: account.id,
        success: true,
        agent_run_id: agent_run.id
      )

      expect(AgentRuns::DispatchCircuitBreaker).to have_received(:record_outcome!).with(
        account: account,
        success: true,
        agent_run_id: agent_run.id
      )
    end

    it "forwards failure outcomes" do
      allow(AgentRuns::DispatchCircuitBreaker).to receive(:record_outcome!)

      described_class.perform_now(
        account_id: account.id,
        success: false,
        agent_run_id: agent_run.id
      )

      expect(AgentRuns::DispatchCircuitBreaker).to have_received(:record_outcome!).with(
        account: account,
        success: false,
        agent_run_id: agent_run.id
      )
    end

    it "discards missing accounts" do
      allow(AgentRuns::DispatchCircuitBreaker).to receive(:record_outcome!)

      expect {
        described_class.perform_now(account_id: -1, success: true, agent_run_id: agent_run.id)
      }.not_to raise_error
      expect(AgentRuns::DispatchCircuitBreaker).not_to have_received(:record_outcome!)
    end
  end
end
