# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe GithubHealthState do
  def wait_for_queue(queue, timeout: 5)
    Timeout.timeout(timeout) { queue.pop }
  end

  def run_success_failure_race(state)
    success_state = described_class.find(state.id)
    failure_state = described_class.find(state.id)
    update_started = Queue.new
    continue_update = Queue.new
    failure_started = Queue.new
    failure_updated = Queue.new

    allow(success_state).to receive(:update!).and_wrap_original do |method, *args|
      update_started << true
      wait_for_queue(continue_update)
      method.call(*args)
    end
    allow(failure_state).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      failure_started << true
      method.call(*args, &block)
    end
    allow(failure_state).to receive(:update!).and_wrap_original do |method, *args|
      failure_updated << true
      method.call(*args)
    end

    success_thread = Thread.new do
      success_state.record_success!
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end
    wait_for_queue(update_started)
    failure_thread = Thread.new do
      failure_state.record_failure!(error_message: "probe failed")
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end
    wait_for_queue(failure_started)

    expect { wait_for_queue(failure_updated, timeout: 2) }.to raise_error(Timeout::Error)

    continue_update << true
    [ success_thread, failure_thread ].each(&:value)
  end

  def run_recovery_race(state)
    first_state = described_class.find(state.id)
    second_state = described_class.find(state.id)
    update_started = Queue.new
    continue_update = Queue.new

    allow(first_state).to receive(:update!).and_wrap_original do |method, *args|
      update_started << true
      wait_for_queue(continue_update)
      method.call(*args)
    end

    first_result = nil
    second_result = nil

    first_thread = Thread.new do
      first_result = first_state.check_circuit_recovery!(timeout: 300)
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end
    wait_for_queue(update_started)
    second_thread = Thread.new do
      second_result = second_state.check_circuit_recovery!(timeout: 300)
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end
    continue_update << true

    [ first_thread, second_thread ].each(&:value)
    [ first_result, second_result ]
  end

  describe "validations" do
    subject { build(:github_health_state) }

    it { is_expected.to validate_presence_of(:endpoint) }
    it { is_expected.to validate_length_of(:endpoint).is_at_most(50) }
    it { is_expected.to validate_uniqueness_of(:endpoint) }
    it { is_expected.to validate_presence_of(:circuit_state) }
    it { is_expected.to validate_inclusion_of(:circuit_state).in_array(described_class::CIRCUIT_STATES) }
    it { is_expected.to validate_numericality_of(:failure_count).only_integer.is_greater_than_or_equal_to(0) }
  end

  describe ".current" do
    it "creates a new record when none exists" do
      expect { described_class.current }.to change(described_class, :count).by(1)
    end

    it "returns the existing record when one exists" do
      existing = create(:github_health_state)
      expect(described_class.current).to eq(existing)
    end

    it "looks up scoped records by endpoint" do
      existing = create(:github_health_state, endpoint: described_class.endpoint_for_github_token(42))

      expect(described_class.current(endpoint: described_class.endpoint_for_github_token(42))).to eq(existing)
    end
  end

  describe "endpoint helpers" do
    it "builds a scoped endpoint for GitHub tokens" do
      expect(described_class.endpoint_for_github_token(42)).to eq("github_token:42")
    end

    it "builds a scoped endpoint for GitHub App installations" do
      expect(described_class.endpoint_for_github_installation(1234)).to eq("github_installation:1234")
    end
  end

  describe ".github_available?" do
    it "returns true when no state record exists" do
      expect(described_class.github_available?).to be true
    end

    it "returns true when circuit is closed" do
      create(:github_health_state)
      expect(described_class.github_available?).to be true
    end

    it "returns false when circuit is open" do
      create(:github_health_state, :circuit_open)
      expect(described_class.github_available?).to be false
    end

    it "returns true when circuit is half_open" do
      create(:github_health_state, :circuit_half_open)
      expect(described_class.github_available?).to be true
    end

    it "returns false while a rate-limit window is active" do
      create(:github_health_state, :rate_limited)
      expect(described_class.github_available?).to be false
    end

    it "returns true after the rate-limit window has elapsed" do
      create(:github_health_state, rate_limited_until: 1.minute.ago)
      expect(described_class.github_available?).to be true
    end
  end

  describe ".github_available_with_recovery?" do
    it "returns true when no state exists" do
      expect(described_class.github_available_with_recovery?).to be true
    end

    it "returns false when circuit is open and timeout has not elapsed" do
      create(:github_health_state, circuit_state: "open", circuit_opened_at: 1.minute.ago)
      expect(described_class.github_available_with_recovery?).to be false
    end

    it "transitions to half_open and returns true when timeout has elapsed" do
      state = create(:github_health_state, circuit_state: "open", circuit_opened_at: 10.minutes.ago)
      expect(described_class.github_available_with_recovery?).to be true
      expect(state.reload.circuit_state).to eq("half_open")
    end

    it "returns false while a rate-limit window is active even if the circuit is closed" do
      create(:github_health_state, :rate_limited)
      expect(described_class.github_available_with_recovery?).to be false
    end
  end

  describe "#record_failure!" do
    it "increments failure_count" do
      state = create(:github_health_state, failure_count: 2)
      state.record_failure!

      expect(state.reload.failure_count).to eq(3)
    end

    it "opens the circuit when threshold is reached" do
      state = create(:github_health_state, failure_count: 4, circuit_state: "closed")
      state.record_failure!(threshold: 5)

      state.reload
      expect(state.circuit_state).to eq("open")
      expect(state.circuit_opened_at).to be_present
    end

    it "does not reopen an already open circuit" do
      opened_at = 1.hour.ago
      state = create(:github_health_state, failure_count: 6, circuit_state: "open", circuit_opened_at: opened_at)
      state.record_failure!(threshold: 5)

      expect(state.reload.failure_count).to eq(7)
      expect(state.circuit_state).to eq("open")
    end

    it "stores the error message truncated to 500 chars" do
      state = create(:github_health_state)
      state.record_failure!(error_message: "x" * 600)

      expect(state.reload.last_error_message.length).to eq(500)
    end

    it "logs when opening the circuit" do
      state = create(:github_health_state, failure_count: 4, circuit_state: "closed")

      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "github_health.circuit_opened"
      ))

      state.record_failure!(threshold: 5)
    end

    it "reopens the circuit from half_open on any failure" do
      state = create(:github_health_state, :circuit_half_open)
      state.record_failure!(error_message: "probe failed")

      state.reload
      expect(state.circuit_state).to eq("open")
      expect(state.circuit_opened_at).to be_present
    end

    it "logs when reopening the circuit from half_open" do
      state = create(:github_health_state, :circuit_half_open)

      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "github_health.circuit_reopened"
      ))

      state.record_failure!
    end
  end

  describe "#record_success!" do
    it "resets failure_count and closes the circuit from half_open" do
      state = create(:github_health_state, :circuit_half_open)
      state.record_success!

      state.reload
      expect(state.failure_count).to eq(0)
      expect(state.circuit_state).to eq("closed")
      expect(state.circuit_opened_at).to be_nil
      expect(state.last_error_message).to be_nil
    end

    it "logs when closing a half_open circuit" do
      state = create(:github_health_state, :circuit_half_open)

      expect(Rails.logger).to receive(:info).with(hash_including(
        message: "github_health.circuit_closed"
      ))

      state.record_success!
    end

    it "is a no-op when circuit is open (must go through half_open first)" do
      state = create(:github_health_state, :circuit_open)

      expect(state).not_to receive(:update!)
      state.record_success!
    end

    it "is a no-op when already closed with zero failures" do
      state = create(:github_health_state)

      expect(state).not_to receive(:update!)
      state.record_success!
    end

    it "resets failure_count when closed but has accumulated failures" do
      state = create(:github_health_state, failure_count: 3)
      state.record_success!

      state.reload
      expect(state.failure_count).to eq(0)
    end

    it "clears rate_limited_until on a successful call" do
      state = create(:github_health_state, rate_limited_until: 1.hour.from_now)
      state.record_success!

      expect(state.reload.rate_limited_until).to be_nil
    end

    it "does not overwrite an open circuit when a failure races with success" do
      state = create(:github_health_state, :circuit_half_open)
      run_success_failure_race(state)

      state.reload
      expect(state.circuit_state).to eq("closed")
      expect(state.failure_count).to eq(1)
      expect(state.last_error_message).to eq("probe failed")
    end
  end

  describe "#check_circuit_recovery!" do
    it "transitions from open to half_open after timeout" do
      state = create(:github_health_state, circuit_state: "open", circuit_opened_at: 10.minutes.ago)
      result = state.check_circuit_recovery!(timeout: 300)

      expect(result).to be true
      expect(state.reload.circuit_state).to eq("half_open")
    end

    it "does not transition if timeout has not elapsed" do
      state = create(:github_health_state, circuit_state: "open", circuit_opened_at: 1.minute.ago)
      result = state.check_circuit_recovery!(timeout: 300)

      expect(result).to be false
      expect(state.reload.circuit_state).to eq("open")
    end

    it "returns false for closed circuits" do
      state = create(:github_health_state, circuit_state: "closed")
      expect(state.check_circuit_recovery!(timeout: 300)).to be false
    end

    it "allows only one concurrent recovery transition" do
      state = create(:github_health_state, circuit_state: "open", circuit_opened_at: 10.minutes.ago)
      first_result, second_result = run_recovery_race(state)

      expect([ first_result, second_result ].count(true)).to eq(1)
      expect(state.reload.circuit_state).to eq("half_open")
    end
  end

  describe "#circuit_open?" do
    it { expect(build(:github_health_state, circuit_state: "open")).to be_circuit_open }
    it { expect(build(:github_health_state, circuit_state: "closed")).not_to be_circuit_open }
  end

  describe "#circuit_half_open?" do
    it { expect(build(:github_health_state, :circuit_half_open)).to be_circuit_half_open }
    it { expect(build(:github_health_state)).not_to be_circuit_half_open }
  end

  describe "#circuit_closed?" do
    it { expect(build(:github_health_state)).to be_circuit_closed }
    it { expect(build(:github_health_state, :circuit_open)).not_to be_circuit_closed }
  end

  describe "#unavailable?" do
    it "returns true when circuit is open" do
      state = build(:github_health_state, :circuit_open)
      expect(state).to be_unavailable
    end

    it "returns false when circuit is closed" do
      state = build(:github_health_state)
      expect(state).not_to be_unavailable
    end

    it "returns false when circuit is half_open" do
      state = build(:github_health_state, :circuit_half_open)
      expect(state).not_to be_unavailable
    end

    it "returns true while a rate-limit window is active" do
      state = build(:github_health_state, :rate_limited)
      expect(state).to be_unavailable
    end

    it "returns false once the rate-limit window has elapsed" do
      state = build(:github_health_state, rate_limited_until: 1.minute.ago)
      expect(state).not_to be_unavailable
    end
  end

  describe "#rate_limited?" do
    it "returns true when rate_limited_until is in the future" do
      state = build(:github_health_state, :rate_limited)
      expect(state).to be_rate_limited
    end

    it "returns false when rate_limited_until is nil" do
      state = build(:github_health_state)
      expect(state).not_to be_rate_limited
    end

    it "returns false when rate_limited_until has already elapsed" do
      state = build(:github_health_state, rate_limited_until: 1.minute.ago)
      expect(state).not_to be_rate_limited
    end
  end

  describe "#mark_rate_limited!" do
    it "persists the supplied reset_at" do
      state = create(:github_health_state)
      reset_at = 30.minutes.from_now

      state.mark_rate_limited!(reset_at: reset_at)

      expect(state.reload.rate_limited_until).to be_within(1.second).of(reset_at)
    end

    it "defaults to 60 seconds from now when reset_at is nil" do
      state = create(:github_health_state)
      freeze_time do
        state.mark_rate_limited!(reset_at: nil)
        expect(state.reload.rate_limited_until).to eq(60.seconds.from_now)
      end
    end

    it "logs a warning that includes the reset time" do
      state = create(:github_health_state)
      reset_at = 30.minutes.from_now

      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "github_health.rate_limited",
        rate_limited_until: reset_at.iso8601
      ))

      state.mark_rate_limited!(reset_at: reset_at)
    end

    it "is treated as unavailable immediately after being marked" do
      state = create(:github_health_state)
      state.mark_rate_limited!(reset_at: 1.hour.from_now)

      expect(described_class.github_available?).to be false
    end
  end
end
