# frozen_string_literal: true

require "rails_helper"

RSpec.describe RemediationDecisionOutcomeJob, :no_db do
  describe "#perform" do
    let(:pending_outcome) { instance_double(ActiveRecord::Relation, exists?: pending?) }
    let(:remediation_decisions) { double(pending_outcome: pending_outcome) }
    let(:account) { instance_double(Account, id: 1, remediation_decisions: remediation_decisions) }
    let(:pending?) { false }

    before do
      allow(TenantContext).to receive(:with_system_access).and_yield
      allow(Account).to receive(:find_each).and_yield(account)
      allow(AgentRunPatterns::UpdateOutcomes).to receive(:call)
      allow(AgentRunPatterns::Detect).to receive(:call)
    end

    it "skips accounts without pending outcomes without detecting patterns" do
      described_class.perform_now

      expect(AgentRunPatterns::Detect).not_to have_received(:call)
      expect(AgentRunPatterns::UpdateOutcomes).not_to have_received(:call)
    end

    it "evaluates accounts with pending outcomes without detecting patterns" do
      allow(pending_outcome).to receive(:exists?).and_return(true)

      described_class.perform_now

      expect(AgentRunPatterns::Detect).not_to have_received(:call)
      expect(AgentRunPatterns::UpdateOutcomes).to have_received(:call).with(account: account)
    end
  end
end
