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
  end

  describe "#check_recovery!" do
    it "transitions from open to half_open after timeout" do
      breaker = create(:dispatch_circuit_breaker, :open, circuit_opened_at: 10.minutes.ago)

      result = breaker.check_recovery!

      expect(result).to be true
      expect(breaker.reload).to be_circuit_half_open
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
    it "increments failure count" do
      breaker = create(:dispatch_circuit_breaker, :half_open)

      breaker.record_half_open_failure!

      expect(breaker.reload.half_open_failure_count).to eq(1)
    end

    it "re-opens circuit when threshold reached" do
      breaker = create(:dispatch_circuit_breaker, :half_open, half_open_failure_count: 1)

      breaker.record_half_open_failure!

      expect(breaker.reload).to be_circuit_open
      expect(breaker.half_open_failure_count).to eq(0)
    end
  end

  describe "#record_half_open_success!" do
    it "increments success count" do
      breaker = create(:dispatch_circuit_breaker, :half_open)

      breaker.record_half_open_success!

      expect(breaker.reload.half_open_success_count).to eq(1)
    end

    it "closes circuit when threshold reached" do
      breaker = create(:dispatch_circuit_breaker, :half_open, half_open_success_count: 1)

      breaker.record_half_open_success!

      expect(breaker.reload).to be_circuit_closed
    end
  end

  describe "#close!" do
    it "resets to closed state" do
      breaker = create(:dispatch_circuit_breaker, :open)

      breaker.close!

      expect(breaker.reload).to be_circuit_closed
      expect(breaker.circuit_opened_at).to be_nil
      expect(breaker.last_probe_at).to be_nil
      expect(breaker.trip_metadata).to eq({})
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
end
