# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::DispatchCircuitBreaker do
  let(:account) { create(:account) }

  describe ".halted?" do
    it "returns false when no breaker exists" do
      expect(described_class.halted?(account)).to be false
    end

    it "returns false when breaker is closed" do
      create(:dispatch_circuit_breaker, account: account)
      expect(described_class.halted?(account)).to be false
    end

    it "returns true when breaker is open" do
      create(:dispatch_circuit_breaker, :open, account: account)
      expect(described_class.halted?(account)).to be true
    end

    it "returns false when breaker transitions to half_open and probe allowed" do
      create(:dispatch_circuit_breaker, :open, account: account,
        circuit_opened_at: 10.minutes.ago)
      expect(described_class.halted?(account)).to be false
    end
  end

  describe ".evaluate!" do
    it "does not trip when there are no recent runs" do
      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).not_to be_persisted
    end

    it "does not trip when fewer than min_runs" do
      project = create(:project, account: account)
      5.times do
        create(:agent_run, :failed, project: project, final_runner: "claude_code",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).not_to be_persisted
    end

    it "does not trip when only some providers are failing" do
      project = create(:project, account: account)
      10.times do
        create(:agent_run, :failed, project: project, final_runner: "claude_code",
          completed_at: 5.minutes.ago)
      end
      10.times do
        create(:agent_run, :completed, project: project, final_runner: "opencode",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).not_to be_persisted
    end

    it "trips when all providers exceed failure threshold" do
      project = create(:project, account: account)
      10.times do
        create(:agent_run, :failed, project: project, final_runner: "claude_code",
          completed_at: 5.minutes.ago)
      end
      10.times do
        create(:agent_run, :failed, project: project, final_runner: "opencode",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_open
      expect(breaker.trip_metadata["total_runs"]).to eq(20)
    end
  end

  describe ".record_outcome!" do
    context "when circuit is half_open" do
      it "records success and closes when threshold reached" do
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account,
          half_open_success_count: 1)

        described_class.record_outcome!(account: account, runner_name: "claude_code", success: true)

        expect(breaker.reload).to be_circuit_closed
      end

      it "records failure and re-opens when threshold reached" do
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account,
          half_open_failure_count: 1)

        described_class.record_outcome!(account: account, runner_name: "claude_code", success: false)

        expect(breaker.reload).to be_circuit_open
      end
    end

    context "when circuit is closed" do
      it "evaluates whether to trip on failure" do
        breaker = create(:dispatch_circuit_breaker, account: account)
        project = create(:project, account: account)
        15.times do
          create(:agent_run, :failed, project: project, final_runner: "claude_code",
            completed_at: 5.minutes.ago)
        end

        described_class.record_outcome!(account: account, runner_name: "claude_code", success: false)

        expect(breaker.reload).to be_circuit_open
      end
    end
  end

  describe ".allow_probe?" do
    it "returns false when no breaker exists" do
      expect(described_class.allow_probe?(account)).to be false
    end

    it "returns false when breaker is closed" do
      create(:dispatch_circuit_breaker, account: account)
      expect(described_class.allow_probe?(account)).to be false
    end

    it "returns true when half_open and never probed" do
      create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
      expect(described_class.allow_probe?(account)).to be true
    end

    it "returns false when half_open and recently probed" do
      create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: 1.minute.ago)
      expect(described_class.allow_probe?(account)).to be false
    end
  end
end
