# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerState do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:runner_state) }

    it { is_expected.to validate_presence_of(:runner_name) }
    it { is_expected.to validate_length_of(:runner_name).is_at_most(50) }
    it { is_expected.to validate_presence_of(:circuit_state) }
    it { is_expected.to validate_inclusion_of(:circuit_state).in_array(described_class::CIRCUIT_STATES) }
    it { is_expected.to validate_numericality_of(:failure_count).only_integer.is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:half_open_success_count).only_integer.is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:half_open_failure_count).only_integer.is_greater_than_or_equal_to(0) }
  end

  describe "#rate_limited?" do
    it "returns true when rate_limited_until is in the future" do
      state = build(:runner_state, rate_limited_until: 1.hour.from_now)
      expect(state).to be_rate_limited
    end

    it "returns false when rate_limited_until is in the past" do
      state = build(:runner_state, rate_limited_until: 1.hour.ago)
      expect(state).not_to be_rate_limited
    end

    it "returns false when rate_limited_until is nil" do
      state = build(:runner_state, rate_limited_until: nil)
      expect(state).not_to be_rate_limited
    end
  end

  describe "legacy provider alias" do
    it "maps provider_name to runner_name" do
      state = create(:runner_state, runner_name: "claude")

      state.provider_name = "cursor"
      state.save!

      expect(state.reload.runner_name).to eq("cursor")
    end
  end

  describe "#mark_rate_limited!" do
    it "sets rate_limited_until to the given time" do
      state = create(:runner_state)
      reset_at = 2.hours.from_now
      state.mark_rate_limited!(reset_at: reset_at)

      expect(state.reload.rate_limited_until).to be_within(1.second).of(reset_at)
    end

    it "defaults to 60 seconds from now when no reset_at given" do
      state = create(:runner_state)
      state.mark_rate_limited!

      expect(state.reload.rate_limited_until).to be_within(5.seconds).of(60.seconds.from_now)
    end
  end

  describe "#clear_rate_limit!" do
    it "clears the rate_limited_until" do
      state = create(:runner_state, :rate_limited)
      state.clear_rate_limit!

      expect(state.reload.rate_limited_until).to be_nil
    end
  end

  describe "#record_failure!" do
    it "increments failure_count" do
      state = create(:runner_state, failure_count: 2, last_failure_at: 1.minute.ago)
      state.record_failure!(decay_window: 300)

      expect(state.reload.failure_count).to eq(3)
    end

    it "decays stale failures before incrementing" do
      state = create(:runner_state, failure_count: 8, last_failure_at: 15.minutes.ago)

      state.record_failure!(decay_window: 300)

      expect(state.reload.failure_count).to eq(2)
    end

    it "opens the circuit when threshold is reached" do
      state = create(:runner_state, failure_count: 4, circuit_state: "closed", last_failure_at: 1.minute.ago)
      state.record_failure!(threshold: 5, decay_window: 300)

      state.reload
      expect(state.circuit_state).to eq("open")
      expect(state.circuit_opened_at).to be_present
    end

    it "does not reopen an already open circuit" do
      opened_at = 1.hour.ago
      state = create(:runner_state, failure_count: 6, circuit_state: "open", circuit_opened_at: opened_at,
        last_failure_at: 1.minute.ago)
      state.record_failure!(threshold: 5, decay_window: 300)

      expect(state.reload.failure_count).to eq(7)
      expect(state.circuit_state).to eq("open")
    end

    it "keeps a half-open circuit open through the first failure" do
      state = create(:runner_state, :circuit_half_open, failure_count: 3, circuit_opened_at: 10.minutes.ago)

      state.record_failure!(threshold: 10, half_open_failure_threshold: 2)

      state.reload
      expect(state.failure_count).to eq(4)
      expect(state.circuit_state).to eq("half_open")
      expect(state.half_open_failure_count).to eq(1)
    end

    it "reopens a half-open circuit after repeated failures" do
      state = create(:runner_state, :circuit_half_open, failure_count: 3, circuit_opened_at: 10.minutes.ago,
        half_open_failure_count: 1)

      state.record_failure!(threshold: 10, half_open_failure_threshold: 2)

      state.reload
      expect(state.failure_count).to eq(4)
      expect(state.circuit_state).to eq("open")
      expect(state.half_open_failure_count).to eq(0)
      expect(state.circuit_opened_at).to be_within(5.seconds).of(Time.current)
    end
  end

  describe "#record_success!" do
    it "resets failure_count and closes a closed circuit with accumulated failures" do
      state = create(:runner_state, failure_count: 3, last_failure_at: 1.minute.ago,
        rate_limited_until: 30.minutes.from_now)
      state.record_success!

      state.reload
      expect(state.failure_count).to eq(0)
      expect(state.circuit_state).to eq("closed")
      expect(state.circuit_opened_at).to be_nil
      expect(state.rate_limited_until).to be_nil
      expect(state.last_failure_at).to be_nil
    end

    it "does not close an open circuit before recovery moves it to half-open" do
      state = create(:runner_state, :circuit_open)

      state.record_success!

      expect(state.reload.circuit_state).to eq("open")
    end

    it "keeps a half-open circuit half-open until the success threshold is reached" do
      state = create(:runner_state, :circuit_half_open, failure_count: 4)

      state.record_success!(half_open_success_threshold: 2)

      state.reload
      expect(state.circuit_state).to eq("half_open")
      expect(state.half_open_success_count).to eq(1)
      expect(state.half_open_failure_count).to eq(0)
    end

    it "closes a half-open circuit after enough consecutive successes" do
      state = create(:runner_state, :circuit_half_open, failure_count: 4, half_open_success_count: 1)

      state.record_success!(half_open_success_threshold: 2)

      state.reload
      expect(state.failure_count).to eq(0)
      expect(state.circuit_state).to eq("closed")
      expect(state.half_open_success_count).to eq(0)
      expect(state.half_open_failure_count).to eq(0)
    end
  end

  describe "#check_circuit_recovery!" do
    it "transitions from open to half_open after timeout" do
      state = create(:runner_state, circuit_state: "open", circuit_opened_at: 10.minutes.ago,
        failure_count: 64, last_failure_at: 20.minutes.ago)
      result = state.check_circuit_recovery!(timeout: 300)

      expect(result).to be true
      state.reload
      expect(state.circuit_state).to eq("half_open")
      expect(state.failure_count).to eq(4)
      expect(state.half_open_success_count).to eq(0)
      expect(state.half_open_failure_count).to eq(0)
    end

    it "does not transition if timeout has not elapsed" do
      state = create(:runner_state, circuit_state: "open", circuit_opened_at: 1.minute.ago)
      result = state.check_circuit_recovery!(timeout: 300)

      expect(result).to be false
      expect(state.reload.circuit_state).to eq("open")
    end

    it "clears rate_limited_until when transitioning to half_open" do
      state = create(:runner_state, circuit_state: "open", circuit_opened_at: 10.minutes.ago,
        rate_limited_until: 30.minutes.from_now)
      state.check_circuit_recovery!(timeout: 300)

      state.reload
      expect(state.circuit_state).to eq("half_open")
      expect(state.rate_limited_until).to be_nil
    end

    it "does not transition when timeout has not elapsed and preserves rate limit" do
      state = create(:runner_state, circuit_state: "open", circuit_opened_at: 1.minute.ago,
        rate_limited_until: 30.minutes.from_now)
      state.check_circuit_recovery!(timeout: 300)

      state.reload
      expect(state.circuit_state).to eq("open")
      expect(state.rate_limited_until).to be_present
    end

    it "returns false for closed circuits" do
      state = create(:runner_state, circuit_state: "closed")
      expect(state.check_circuit_recovery!(timeout: 300)).to be false
    end
  end

  describe "#unavailable?" do
    it "returns true when rate limited" do
      state = build(:runner_state, :rate_limited)
      expect(state).to be_unavailable
    end

    it "returns true when circuit is open" do
      state = build(:runner_state, :circuit_open)
      expect(state).to be_unavailable
    end

    it "returns false when circuit is closed and not rate limited" do
      state = build(:runner_state)
      expect(state).not_to be_unavailable
    end

    it "returns false when circuit is half_open" do
      state = build(:runner_state, :circuit_half_open)
      expect(state).not_to be_unavailable
    end

    it "returns false when circuit is half_open after recovery clears rate limit" do
      state = create(:runner_state, circuit_state: "open", circuit_opened_at: 10.minutes.ago,
        rate_limited_until: 30.minutes.from_now)
      state.check_circuit_recovery!(timeout: 300)

      expect(state).not_to be_unavailable
    end
  end

  describe "#circuit_open?" do
    it { expect(build(:runner_state, circuit_state: "open")).to be_circuit_open }
    it { expect(build(:runner_state, circuit_state: "closed")).not_to be_circuit_open }
  end

  describe "#circuit_half_open?" do
    it { expect(build(:runner_state, :circuit_half_open)).to be_circuit_half_open }
    it { expect(build(:runner_state)).not_to be_circuit_half_open }
  end

  describe "#circuit_closed?" do
    it { expect(build(:runner_state)).to be_circuit_closed }
    it { expect(build(:runner_state, :circuit_open)).not_to be_circuit_closed }
  end
end
