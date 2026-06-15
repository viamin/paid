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
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
      expect(breaker.last_evaluated_at).to be_present
    end

    it "does not trip when fewer than min_runs" do
      project = create(:project, account: account)
      5.times do
        create(:agent_run, :failed, project: project, final_runner: "claude_code",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
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
      expect(breaker).to be_persisted
      expect(breaker).to be_circuit_closed
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

    it "skips the query when circuit is already open" do
      breaker = create(:dispatch_circuit_breaker, :open, account: account)
      original_opened_at = breaker.circuit_opened_at

      described_class.evaluate!(account)

      expect(breaker.reload.circuit_opened_at).to be_within(1.second).of(original_opened_at)
    end

    it "is debounced by the last_evaluated_at interval" do
      project = create(:project, account: account)
      15.times do
        create(:agent_run, :failed, project: project, final_runner: "claude_code",
          completed_at: 5.minutes.ago)
      end

      described_class.evaluate!(account)

      breaker = DispatchCircuitBreaker.for_account(account)
      expect(breaker.last_evaluated_at).to be_present
      first_evaluated_at = breaker.last_evaluated_at

      described_class.evaluate!(account)

      expect(breaker.reload.last_evaluated_at).to eq(first_evaluated_at)
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

      it "is debounced — does not re-evaluate within the interval" do
        breaker = create(:dispatch_circuit_breaker, account: account,
          last_evaluated_at: 10.seconds.ago)
        project = create(:project, account: account)
        15.times do
          create(:agent_run, :failed, project: project, final_runner: "claude_code",
            completed_at: 5.minutes.ago)
        end

        described_class.record_outcome!(account: account, runner_name: "claude_code", success: false)

        expect(breaker.reload).to be_circuit_closed
      end
    end
  end

  describe ".probe_decision" do
    it "returns :dispatch when no breaker exists" do
      expect(described_class.probe_decision(account)).to eq(:dispatch)
    end

    it "returns :dispatch when breaker is closed" do
      create(:dispatch_circuit_breaker, account: account)
      expect(described_class.probe_decision(account)).to eq(:dispatch)
    end

    it "returns :halt when breaker is open" do
      create(:dispatch_circuit_breaker, :open, account: account)
      expect(described_class.probe_decision(account)).to eq(:halt)
    end

    it "returns :allow_probe when half_open and never probed" do
      create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
      expect(described_class.probe_decision(account)).to eq(:allow_probe)
    end

    it "returns :halt when half_open and recently probed" do
      create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: 1.minute.ago)
      expect(described_class.probe_decision(account)).to eq(:halt)
    end

    it "transitions to half_open and returns :allow_probe when open and recovery timeout elapsed" do
      breaker = create(:dispatch_circuit_breaker, :open, account: account,
        circuit_opened_at: 10.minutes.ago)

      expect(described_class.probe_decision(account)).to eq(:allow_probe)
      expect(breaker.reload).to be_circuit_half_open
    end
  end
end
