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
      allow(AgentRunPatterns::DailyDiagnosisBudget).to receive(:remaining_for).and_return(5)
      allow(AgentRunPatterns::RecordRemediationDecision).to receive(:call).and_return(double(id: 99))
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

    it "iterates accounts within system access" do
      in_system_access = false

      allow(TenantContext).to receive(:with_system_access) do |&block|
        in_system_access = true
        block.call
      ensure
        in_system_access = false
      end
      allow(Account).to receive(:find_each) do |&block|
        expect(in_system_access).to be(true)
        block.call(account)
      end

      described_class.perform_now
    end

    context "when patterns are detected" do
      let(:pattern) do
        AgentRunPatterns::Detect::Pattern.new(
          type: :failure_streak,
          goal: "enhance_issue",
          severity: :error,
          details: {
            fingerprint: "fp-1",
            streak_length: 3,
            total_runs: 3,
            failure_rate: 1.0,
            error_messages: [ "Error" ]
          }
        )
      end
      let(:follow_up_pattern) do
        AgentRunPatterns::Detect::Pattern.new(
          type: :error_cluster,
          goal: "enhance_issue",
          severity: :error,
          details: {
            fingerprint: "fp-2",
            sample_messages: [ "GitHub API error: 403 Forbidden" ]
          }
        )
      end
      let(:diagnosis) do
        AgentRunPatterns::Diagnose::Diagnosis.new(
          root_cause: "GitHub API Error",
          confidence: 1.0,
          proposed_action: "file_issue",
          action_target: { "type" => "project", "id" => "7" },
          evidence_pointers: [ "legacy_messages[0]" ]
        )
      end

      before do
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern ])
        allow(AgentRunPatterns::Diagnose).to receive(:call).and_return(diagnosis)
      end

      it "diagnoses each detected pattern with account context" do
        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          pattern,
          account: account,
          allow_llm: true
        )
      end

      it "records a remediation decision for each fingerprint" do
        described_class.perform_now

        expect(AgentRunPatterns::RecordRemediationDecision).to have_received(:call).with(
          account: account,
          pattern: pattern,
          diagnosis: diagnosis
        )
      end

      it "notifies for the account with fingerprint-keyed diagnoses and decisions" do
        described_class.perform_now

        expect(AgentRunPatterns::Notify).to have_received(:call).with(
          account: account,
          patterns: [ pattern ],
          diagnoses: hash_including("fp-1" => diagnosis),
          decisions: hash_including("fp-1")
        )
      end

      it "stops issuing LLM diagnoses after the daily budget is exhausted" do
        allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern, follow_up_pattern ])
        allow(AgentRunPatterns::DailyDiagnosisBudget).to receive(:remaining_for).and_return(1)

        described_class.perform_now

        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          pattern,
          account: account,
          allow_llm: true
        )
        expect(AgentRunPatterns::Diagnose).to have_received(:call).with(
          follow_up_pattern,
          account: account,
          allow_llm: false
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
          diagnoses: {},
          decisions: {}
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
