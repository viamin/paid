# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::ConcurrentStatsSampler do
  describe ".call" do
    it "returns results in the same order as the input containers" do
      containers = %w[a b c d e]

      results = described_class.call(
        containers: containers,
        monotonic_deadline: monotonic_now + 5,
        per_container_timeout: 1
      ) { |container| container.upcase }

      expect(results.map(&:container)).to eq(containers)
      expect(results.map(&:raw_stats)).to eq(%w[A B C D E])
      expect(results).to all(be_success)
    end

    it "samples containers concurrently instead of scaling linearly with count" do
      containers = Array.new(6) { |i| i }
      started_at = monotonic_now

      results = described_class.call(
        containers: containers,
        monotonic_deadline: started_at + 5,
        per_container_timeout: 2
      ) { |_container| sleep 0.3; :ok }

      elapsed = monotonic_now - started_at

      expect(results).to all(be_success)
      expect(elapsed).to be < (6 * 0.3)
    end

    it "marks a container as skipped without invoking the block when the deadline has already passed" do
      results = described_class.call(
        containers: [ :only ],
        monotonic_deadline: monotonic_now - 1,
        per_container_timeout: 1
      ) { |_container| raise "should not be called" }

      expect(results.first.skipped).to be(true)
      expect(results.first).not_to be_success
    end

    it "captures a per-container error without aborting the other containers" do
      results = described_class.call(
        containers: [ :ok, :boom ],
        monotonic_deadline: monotonic_now + 5,
        per_container_timeout: 1
      ) { |container| container == :boom ? raise("kaboom") : :fine }

      ok_result = results.find { |r| r.container == :ok }
      boom_result = results.find { |r| r.container == :boom }

      expect(ok_result).to be_success
      expect(boom_result.error).to be_a(RuntimeError)
      expect(boom_result).not_to be_success
    end

    it "times out a slow container without blocking a fast one" do
      results = described_class.call(
        containers: [ :slow, :fast ],
        monotonic_deadline: monotonic_now + 5,
        per_container_timeout: 0.05,
        max_threads: 2
      ) { |container| container == :slow ? sleep(1) : :fine }

      slow_result = results.find { |r| r.container == :slow }
      fast_result = results.find { |r| r.container == :fast }

      expect(slow_result.error).to be_a(Timeout::Error)
      expect(fast_result).to be_success
    end

    it "bounds concurrency to max_threads" do
      concurrent = 0
      peak = 0
      mutex = Mutex.new

      described_class.call(
        containers: Array.new(10) { |i| i },
        monotonic_deadline: monotonic_now + 5,
        per_container_timeout: 1,
        max_threads: 3
      ) do |_container|
        mutex.synchronize { concurrent += 1; peak = [ peak, concurrent ].max }
        sleep 0.05
        mutex.synchronize { concurrent -= 1 }
      end

      expect(peak).to be <= 3
    end

    it "returns an empty array for no containers" do
      results = described_class.call(
        containers: [],
        monotonic_deadline: monotonic_now + 1,
        per_container_timeout: 1
      ) { |container| container }

      expect(results).to eq([])
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
