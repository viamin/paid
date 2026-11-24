# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/paid/good_job_worker"

RSpec.describe Paid::GoodJobWorker do
  # @spec RAILS-CONTROL-PLANE-030
  describe Paid::GoodJobWorker::HealthMonitor do
    let(:now) { Time.utc(2026, 11, 23, 8, 5, 0) }
    let(:process) { { updated_at: now - 10, schedulers: [ { active_threads: 0, available_threads: 1 } ] } }
    let(:snapshot) { { process:, runnable_jobs: 0 } }

    it "keeps a fresh idle worker healthy" do
      monitor = described_class.new(now: -> { now })

      expect(monitor.observe(snapshot)).to be_healthy
    end

    it "degrades when the GoodJob heartbeat is stale" do
      monitor = described_class.new(now: -> { now }, heartbeat_timeout: 30)

      result = monitor.observe(snapshot.merge(process: process.merge(updated_at: now - 31)))

      expect(result).to be_degraded
      expect(result.reason).to eq(:stale_process_heartbeat)
    end

    it "does not mistake a legitimately long-running fully occupied worker for stalled progress" do
      monitor = described_class.new(now: -> { now }, progress_timeout: 30)
      occupied = snapshot.merge(process: process.merge(schedulers: [ { active_threads: 1, available_threads: 0 } ]), runnable_jobs: 1)

      expect(monitor.observe(occupied)).to be_healthy
      expect(monitor.observe(occupied, now: now + 60)).to be_healthy
    end

    it "degrades boundedly when runnable work waits with an available scheduler thread" do
      monitor = described_class.new(now: -> { now }, progress_timeout: 30)
      blocked = snapshot.merge(runnable_jobs: 1)

      expect(monitor.observe(blocked)).to be_healthy
      result = monitor.observe(blocked, now: now + 31)

      expect(result).to be_degraded
      expect(result.reason).to eq(:stalled_queue_progress)
    end

    it "degrades when process visibility is unavailable" do
      monitor = described_class.new(now: -> { now }, heartbeat_timeout: 30)
      unavailable = snapshot.merge(process: nil)

      expect(monitor.observe(unavailable)).to be_healthy
      expect(monitor.observe(unavailable, now: now + 31)).to have_attributes(degraded?: true, reason: :missing_process_heartbeat)
    end
  end

  # @spec RAILS-CONTROL-PLANE-030
  describe Paid::GoodJobWorker::RecoveryCoordinator do
    it "withdraws readiness and starts one graceful shutdown without changing job ownership" do
      events = []
      readiness = Object.new.tap do |object|
        object.define_singleton_method(:mark_not_ready!) { events << :not_ready }
      end
      coordinator = described_class.new(readiness:, shutdown: -> { events << :graceful_shutdown })

      expect(coordinator.recover).to be(true)
      expect(coordinator.recover).to be(false)
      expect(events).to eq(%i[not_ready graceful_shutdown])
    end
  end

  describe ".min_required_db_pool" do
    it "adds the capsule overhead to the configured thread count" do
      expect(described_class.min_required_db_pool(max_threads: 11)).to eq(11 + described_class::DB_POOL_OVERHEAD)
    end

    it "scales with the thread count" do
      expect(described_class.min_required_db_pool(max_threads: 1)).to eq(1 + described_class::DB_POOL_OVERHEAD)
      expect(described_class.min_required_db_pool(max_threads: 30)).to eq(30 + described_class::DB_POOL_OVERHEAD)
    end
  end

  describe ".force_exit_buffer" do
    it "defaults to the documented constant" do
      expect(described_class.force_exit_buffer({})).to eq(described_class::DEFAULT_FORCE_EXIT_BUFFER)
    end

    it "honours GOOD_JOB_FORCE_EXIT_BUFFER_SECONDS" do
      env = { "GOOD_JOB_FORCE_EXIT_BUFFER_SECONDS" => "7" }
      expect(described_class.force_exit_buffer(env)).to eq(7)
    end

    it "falls back to the default when the override is not parseable" do
      env = { "GOOD_JOB_FORCE_EXIT_BUFFER_SECONDS" => "soon" }
      expect(described_class.force_exit_buffer(env)).to eq(described_class::DEFAULT_FORCE_EXIT_BUFFER)
    end
  end

  describe ".forced_exit_timeout" do
    it "sums the graceful window and the force-exit buffer" do
      result = described_class.forced_exit_timeout(shutdown_timeout: 25, force_exit_buffer: 10)
      expect(result).to eq(35)
    end
  end

  describe Paid::GoodJobWorker::ShutdownCoordinator do
    it "requests graceful shutdown on the first trigger" do
      coordinator = described_class.new

      expect(coordinator.trigger).to eq(:graceful)
      expect(coordinator).to be_shutdown_started
    end

    it "forces an exit on every subsequent trigger" do
      coordinator = described_class.new
      coordinator.trigger

      expect(coordinator.trigger).to eq(:force_exit)
      expect(coordinator.trigger).to eq(:force_exit)
    end

    it "is thread-safe under concurrent triggers" do
      coordinator = described_class.new
      triggers = Array.new(20) { Thread.new { coordinator.trigger } }.map(&:value)

      expect(triggers.count(:graceful)).to eq(1)
      expect(triggers.count(:force_exit)).to eq(19)
    end
  end
end
