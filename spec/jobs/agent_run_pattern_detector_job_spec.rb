# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatternDetectorJob, :no_db do
  describe "#perform" do
    let(:account) { Struct.new(:id).new(1) }

    before do
      stub_const("Account", Class.new do
        def self.find_each; end
      end)
      allow(AgentRunPatterns::Detect).to receive(:call).and_return([])
      allow(AgentRunPatterns::Diagnose).to receive(:call)
      allow(AgentRunPatterns::Notify).to receive(:call)
      allow(TenantContext).to receive(:with_system_access).and_yield
      allow(Account).to receive(:find_each).and_yield(account)
    end

    it "is enqueued on the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end

    it "detects patterns for each account" do
      described_class.perform_now

      expect(TenantContext).to have_received(:with_system_access).at_least(:once)
      expect(AgentRunPatterns::Detect).to have_received(:call).with(account: account)
    end

    context "when patterns are detected" do
      let(:pattern) do
        AgentRunPatterns::Detect::Pattern.new(
          type: :failure_streak,
          goal: "enhance_issue",
          severity: :error,
          details: { streak_length: 3, total_runs: 3, failure_rate: 1.0, error_messages: [ "Error" ] }
        )
      end

      before do
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern ])
      end

      it "diagnoses each detected pattern" do
        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(pattern)
      end

      it "notifies for the account" do
        described_class.perform_now

        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: account,
          patterns: [ pattern ],
          diagnoses: hash_including("enhance_issue")
        )
      end
    end

    context "when no patterns are detected" do
      it "skips diagnosis and still runs notification resolution" do
        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).not_to have_received(:call)
        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: account,
          patterns: [],
          diagnoses: {}
        )
      end
    end

    context "when detection raises for one account" do
      let(:other_account) { Struct.new(:id).new(2) }

      before do
        allow(Account).to receive(:find_each).and_yield(account).and_yield(other_account)
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_raise(StandardError, "boom")
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: other_account).and_return([])
      end

      it "continues processing remaining accounts" do
        expect { described_class.perform_now }.not_to raise_error

        expect(AgentRunPatterns::Detect).to have_received(:call).with(account: other_account)
      end

      it "logs a warning for the failed account" do
        allow(Rails.logger).to receive(:warn)

        described_class.perform_now

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "agent_run_patterns.detection_failed_for_account",
            account_id: account.id,
            error_class: "StandardError"
          )
        )
      end
    end
  end
end
