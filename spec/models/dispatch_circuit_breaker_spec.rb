# frozen_string_literal: true

require "rails_helper"

RSpec.describe DispatchCircuitBreaker do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
  end

  describe "validations" do
    subject { build(:dispatch_circuit_breaker) }

    it { is_expected.to validate_presence_of(:circuit_state) }
    it { is_expected.to validate_inclusion_of(:circuit_state).in_array(described_class::CIRCUIT_STATES) }
    it { is_expected.to validate_numericality_of(:half_open_success_count).only_integer.is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:half_open_failure_count).only_integer.is_greater_than_or_equal_to(0) }
  end

  describe ".for_account" do
    it "returns a new record when none exists" do
      account = create(:account)
      breaker = described_class.for_account(account)

      expect(breaker).not_to be_persisted
      expect(breaker.account).to eq(account)
    end

    it "returns existing record when one exists" do
      account = create(:account)
      existing = create(:dispatch_circuit_breaker, account: account)

      breaker = described_class.for_account(account)
      expect(breaker).to eq(existing)
    end
  end

  describe ".for_account!" do
    it "creates a new record when none exists" do
      account = create(:account)

      expect { described_class.for_account!(account) }.to change(described_class, :count).by(1)
    end

    it "returns existing record when one exists" do
      account = create(:account)
      existing = create(:dispatch_circuit_breaker, account: account)

      expect(described_class.for_account!(account)).to eq(existing)
    end
  end

  describe "#circuit_open?" do
    it "returns true when state is open" do
      breaker = build(:dispatch_circuit_breaker, :open)
      expect(breaker).to be_circuit_open
    end

    it "returns false when state is closed" do
      breaker = build(:dispatch_circuit_breaker)
      expect(breaker).not_to be_circuit_open
    end
  end

  describe "#circuit_half_open?" do
    it "returns true when state is half_open" do
      breaker = build(:dispatch_circuit_breaker, :half_open)
      expect(breaker).to be_circuit_half_open
    end
  end

  describe "#circuit_closed?" do
    it "returns true when state is closed" do
      breaker = build(:dispatch_circuit_breaker)
      expect(breaker).to be_circuit_closed
    end
  end

  describe "#trip!" do
    it "transitions from closed to open" do
      breaker = create(:dispatch_circuit_breaker)
      metadata = { "failure_rate" => 0.95 }

      breaker.trip!(metadata: metadata)

      expect(breaker.reload).to be_circuit_open
      expect(breaker.circuit_opened_at).to be_within(1.second).of(Time.current)
      expect(breaker.trip_metadata).to eq(metadata)
    end

    it "clears any leftover last_probe_run_id from a prior half_open cycle" do
      probe = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :open, last_probe_run_id: probe.id)

      breaker.trip!

      expect(breaker.reload.last_probe_run_id).to be_nil
    end
  end

  describe "#check_recovery!" do
    it "transitions from open to half_open after timeout" do
      breaker = create(:dispatch_circuit_breaker, :open, circuit_opened_at: 10.minutes.ago)

      result = breaker.check_recovery!

      expect(result).to be true
      expect(breaker.reload).to be_circuit_half_open
    end

    it "clears any leftover probe tracking so the new probe is the only tracked one" do
      stale_probe = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :open,
        circuit_opened_at: 10.minutes.ago,
        last_probe_at: 1.minute.ago,
        last_probe_run_id: stale_probe.id)

      breaker.check_recovery!

      reloaded = breaker.reload
      expect(reloaded).to be_circuit_half_open
      expect(reloaded.last_probe_run_id).to be_nil
      expect(reloaded.last_probe_at).to be_nil
    end

    it "allows a probe immediately after recovery even when recovery timeout is shorter than probe interval" do
      # Regression: a prior half_open probe leaves last_probe_at behind. If
      # recovery_timeout_minutes < probe_interval_minutes the breaker reached
      # half_open but probe_allowed? stayed false until the stale probe
      # interval elapsed, making the recovery-timeout setting ineffective.
      account = create(:account)
      create(:tenant_setting, account: account, agent_settings: {
        "dispatch_circuit_breaker_recovery_timeout_minutes" => 1,
        "dispatch_circuit_breaker_probe_interval_minutes" => 10
      })
      breaker = create(:dispatch_circuit_breaker, :open, account: account,
        circuit_opened_at: 2.minutes.ago,
        last_probe_at: 30.seconds.ago)

      breaker.check_recovery!

      expect(breaker.reload).to be_probe_allowed
    end

    it "does not transition before timeout" do
      breaker = create(:dispatch_circuit_breaker, :open, circuit_opened_at: 1.second.ago)

      result = breaker.check_recovery!

      expect(result).to be false
      expect(breaker.reload).to be_circuit_open
    end

    it "does nothing when circuit is closed" do
      breaker = create(:dispatch_circuit_breaker)

      result = breaker.check_recovery!

      expect(result).to be false
      expect(breaker.reload).to be_circuit_closed
    end
  end

  describe "#record_half_open_failure!" do
    it "increments failure count for the tracked probe" do
      probe = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_run_id: probe.id)

      breaker.record_half_open_failure!(agent_run_id: probe.id)

      expect(breaker.reload.half_open_failure_count).to eq(1)
    end

    it "is a no-op for a stale in-flight run that is not the tracked probe" do
      probe = create(:agent_run)
      stale = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_run_id: probe.id)

      result = breaker.record_half_open_failure!(agent_run_id: stale.id)

      expect(result).to eq(:stale)
      expect(breaker.reload.half_open_failure_count).to eq(0)
      expect(breaker).to be_circuit_half_open
    end

    it "is a no-op when no probe has been dispatched yet" do
      breaker = create(:dispatch_circuit_breaker, :half_open)
      run = create(:agent_run)

      result = breaker.record_half_open_failure!(agent_run_id: run.id)

      expect(result).to eq(:stale)
      expect(breaker.reload.half_open_failure_count).to eq(0)
    end

    it "re-opens circuit when threshold reached" do
      probe = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :half_open,
        half_open_failure_count: 1, last_probe_run_id: probe.id)

      breaker.record_half_open_failure!(agent_run_id: probe.id)

      expect(breaker.reload).to be_circuit_open
      expect(breaker.half_open_failure_count).to eq(0)
      expect(breaker.last_probe_run_id).to be_nil
    end
  end

  describe "#record_half_open_success!" do
    it "increments success count for the tracked probe" do
      probe = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_run_id: probe.id)

      breaker.record_half_open_success!(agent_run_id: probe.id)

      expect(breaker.reload.half_open_success_count).to eq(1)
    end

    it "is a no-op for a stale in-flight run that is not the tracked probe" do
      probe = create(:agent_run)
      stale = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_run_id: probe.id)

      result = breaker.record_half_open_success!(agent_run_id: stale.id)

      expect(result).to eq(:stale)
      expect(breaker.reload.half_open_success_count).to eq(0)
      expect(breaker).to be_circuit_half_open
    end

    it "is a no-op when no probe has been dispatched yet" do
      breaker = create(:dispatch_circuit_breaker, :half_open)
      run = create(:agent_run)

      result = breaker.record_half_open_success!(agent_run_id: run.id)

      expect(result).to eq(:stale)
      expect(breaker.reload.half_open_success_count).to eq(0)
    end

    it "closes circuit when threshold reached" do
      probe = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :half_open,
        half_open_success_count: 1, last_probe_run_id: probe.id)

      breaker.record_half_open_success!(agent_run_id: probe.id)

      expect(breaker.reload).to be_circuit_closed
      expect(breaker.last_probe_run_id).to be_nil
    end
  end

  describe "#close!" do
    it "resets to closed state" do
      breaker = create(:dispatch_circuit_breaker, :open)

      breaker.close!

      expect(breaker.reload).to be_circuit_closed
      expect(breaker.circuit_opened_at).to be_nil
      expect(breaker.last_probe_at).to be_nil
      expect(breaker.last_probe_run_id).to be_nil
      expect(breaker.trip_metadata).to eq({})
    end
  end

  describe "#mark_probe_dispatched!" do
    it "stamps the agent_run_id and last_probe_at" do
      probe = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :half_open)

      breaker.mark_probe_dispatched!(agent_run_id: probe.id)

      expect(breaker.reload.last_probe_run_id).to eq(probe.id)
      expect(breaker.last_probe_at).to be_within(1.second).of(Time.current)
    end

    it "replaces a previously tracked probe when called with a new run" do
      old_probe = create(:agent_run)
      new_probe = create(:agent_run)
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_run_id: old_probe.id)

      breaker.mark_probe_dispatched!(agent_run_id: new_probe.id)

      expect(breaker.reload.last_probe_run_id).to eq(new_probe.id)
    end
  end

  describe "#probe_allowed?" do
    it "returns false when circuit is not half_open" do
      breaker = create(:dispatch_circuit_breaker, :open)
      expect(breaker).not_to be_probe_allowed
    end

    it "returns true when half_open and never probed" do
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_at: nil)
      expect(breaker).to be_probe_allowed
    end

    it "returns false when recently probed" do
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_at: 1.minute.ago)
      expect(breaker).not_to be_probe_allowed
    end

    it "returns true when probe interval has elapsed" do
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_at: 10.minutes.ago)
      expect(breaker).to be_probe_allowed
    end
  end

  describe "#halted?" do
    it "returns true when circuit is open" do
      breaker = create(:dispatch_circuit_breaker, :open)
      expect(breaker).to be_halted
    end

    it "returns false when circuit is closed" do
      breaker = create(:dispatch_circuit_breaker)
      expect(breaker).not_to be_halted
    end

    it "returns false when half_open and not recently probed" do
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_at: nil)
      expect(breaker).not_to be_halted
    end

    it "returns true when half_open and recently probed" do
      breaker = create(:dispatch_circuit_breaker, :half_open, last_probe_at: 1.minute.ago)
      expect(breaker).to be_halted
    end
  end

  describe "#evaluation_due?" do
    it "returns true when last_evaluated_at is nil" do
      breaker = build(:dispatch_circuit_breaker, last_evaluated_at: nil)
      expect(breaker).to be_evaluation_due
    end

    it "returns false when last_evaluated_at is within the evaluation interval" do
      breaker = build(:dispatch_circuit_breaker, last_evaluated_at: 10.seconds.ago)
      expect(breaker).not_to be_evaluation_due
    end

    it "returns true when last_evaluated_at is older than the evaluation interval" do
      breaker = build(:dispatch_circuit_breaker, last_evaluated_at: 10.minutes.ago)
      expect(breaker).to be_evaluation_due
    end
  end

  describe "#record_evaluation!" do
    it "stamps last_evaluated_at to the current time" do
      breaker = create(:dispatch_circuit_breaker)

      breaker.record_evaluation!

      expect(breaker.reload.last_evaluated_at).to be_within(1.second).of(Time.current)
    end

    it "does not change circuit_state" do
      breaker = create(:dispatch_circuit_breaker)

      breaker.record_evaluation!

      expect(breaker.reload).to be_circuit_closed
    end
  end

  describe "#claim_evaluation!" do
    it "returns true and stamps last_evaluated_at when due" do
      breaker = create(:dispatch_circuit_breaker, last_evaluated_at: nil)

      result = breaker.claim_evaluation!

      expect(result).to be true
      expect(breaker.reload.last_evaluated_at).to be_within(1.second).of(Time.current)
    end

    it "returns false and leaves last_evaluated_at untouched when not due" do
      breaker = create(:dispatch_circuit_breaker, last_evaluated_at: 5.seconds.ago)
      original = breaker.last_evaluated_at

      result = breaker.claim_evaluation!

      expect(result).to be false
      expect(breaker.reload.last_evaluated_at).to be_within(1.second).of(original)
    end

    it "serializes concurrent callers so only one wins the slot" do
      # Simulate a tight burst of terminal completions racing on
      # claim_evaluation!. The first caller stamps last_evaluated_at and
      # returns true; the rest must observe the freshly-stamped value and
      # return false. We spawn two threads and have each run
      # claim_evaluation! with a brief barrier so they both try to acquire
      # the row lock around the same instant.
      breaker = create(:dispatch_circuit_breaker, last_evaluated_at: 10.minutes.ago)

      mutex = Mutex.new
      cv = ConditionVariable.new
      ready = 0
      results = []

      threads = 2.times.map do
        Thread.new do
          mutex.synchronize do
            ready += 1
            cv.broadcast if ready == 2
            cv.wait(mutex) until ready == 2
          end
          results << breaker.claim_evaluation!
        end
      end
      threads.each(&:join)

      expect(results.count(true)).to eq(1)
      expect(breaker.reload.last_evaluated_at).to be_within(2.seconds).of(Time.current)
    end
  end
end
