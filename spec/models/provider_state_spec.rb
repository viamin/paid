# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProviderState do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:provider_state) }

    it { is_expected.to validate_presence_of(:provider_name) }
    it { is_expected.to validate_length_of(:provider_name).is_at_most(50) }
    it { is_expected.to validate_presence_of(:circuit_state) }
    it { is_expected.to validate_inclusion_of(:circuit_state).in_array(described_class::CIRCUIT_STATES) }
    it { is_expected.to validate_numericality_of(:failure_count).only_integer.is_greater_than_or_equal_to(0) }
  end

  describe "#rate_limited?" do
    it "returns true when rate_limited_until is in the future" do
      state = build(:provider_state, rate_limited_until: 1.hour.from_now)
      expect(state).to be_rate_limited
    end

    it "returns false when rate_limited_until is in the past" do
      state = build(:provider_state, rate_limited_until: 1.hour.ago)
      expect(state).not_to be_rate_limited
    end

    it "returns false when rate_limited_until is nil" do
      state = build(:provider_state, rate_limited_until: nil)
      expect(state).not_to be_rate_limited
    end
  end

  describe "#mark_rate_limited!" do
    it "sets rate_limited_until to the given time" do
      state = create(:provider_state)
      reset_at = 2.hours.from_now
      state.mark_rate_limited!(reset_at: reset_at)

      expect(state.reload.rate_limited_until).to be_within(1.second).of(reset_at)
    end

    it "defaults to 60 seconds from now when no reset_at given" do
      state = create(:provider_state)
      state.mark_rate_limited!

      expect(state.reload.rate_limited_until).to be_within(5.seconds).of(60.seconds.from_now)
    end
  end

  describe "#clear_rate_limit!" do
    it "clears the rate_limited_until" do
      state = create(:provider_state, :rate_limited)
      state.clear_rate_limit!

      expect(state.reload.rate_limited_until).to be_nil
    end
  end

  describe "#record_failure!" do
    it "increments failure_count" do
      state = create(:provider_state, failure_count: 2)
      state.record_failure!

      expect(state.reload.failure_count).to eq(3)
    end

    it "opens the circuit when threshold is reached" do
      state = create(:provider_state, failure_count: 4, circuit_state: "closed")
      state.record_failure!(threshold: 5)

      state.reload
      expect(state.circuit_state).to eq("open")
      expect(state.circuit_opened_at).to be_present
    end

    it "does not reopen an already open circuit" do
      opened_at = 1.hour.ago
      state = create(:provider_state, failure_count: 6, circuit_state: "open", circuit_opened_at: opened_at)
      state.record_failure!(threshold: 5)

      expect(state.reload.failure_count).to eq(7)
      expect(state.circuit_state).to eq("open")
    end
  end

  describe "#record_success!" do
    it "resets failure_count and closes the circuit" do
      state = create(:provider_state, :circuit_open)
      state.record_success!

      state.reload
      expect(state.failure_count).to eq(0)
      expect(state.circuit_state).to eq("closed")
      expect(state.circuit_opened_at).to be_nil
      expect(state.rate_limited_until).to be_nil
    end
  end

  describe "#check_circuit_recovery!" do
    it "transitions from open to half_open after timeout" do
      state = create(:provider_state, circuit_state: "open", circuit_opened_at: 10.minutes.ago)
      result = state.check_circuit_recovery!(timeout: 300)

      expect(result).to be true
      expect(state.reload.circuit_state).to eq("half_open")
    end

    it "does not transition if timeout has not elapsed" do
      state = create(:provider_state, circuit_state: "open", circuit_opened_at: 1.minute.ago)
      result = state.check_circuit_recovery!(timeout: 300)

      expect(result).to be false
      expect(state.reload.circuit_state).to eq("open")
    end

    it "returns false for closed circuits" do
      state = create(:provider_state, circuit_state: "closed")
      expect(state.check_circuit_recovery!(timeout: 300)).to be false
    end
  end

  describe "#unavailable?" do
    it "returns true when rate limited" do
      state = build(:provider_state, :rate_limited)
      expect(state).to be_unavailable
    end

    it "returns true when circuit is open" do
      state = build(:provider_state, :circuit_open)
      expect(state).to be_unavailable
    end

    it "returns false when circuit is closed and not rate limited" do
      state = build(:provider_state)
      expect(state).not_to be_unavailable
    end

    it "returns false when circuit is half_open" do
      state = build(:provider_state, :circuit_half_open)
      expect(state).not_to be_unavailable
    end
  end

  describe "#circuit_open?" do
    it { expect(build(:provider_state, circuit_state: "open")).to be_circuit_open }
    it { expect(build(:provider_state, circuit_state: "closed")).not_to be_circuit_open }
  end

  describe "#circuit_half_open?" do
    it { expect(build(:provider_state, :circuit_half_open)).to be_circuit_half_open }
    it { expect(build(:provider_state)).not_to be_circuit_half_open }
  end

  describe "#circuit_closed?" do
    it { expect(build(:provider_state)).to be_circuit_closed }
    it { expect(build(:provider_state, :circuit_open)).not_to be_circuit_closed }
  end
end
