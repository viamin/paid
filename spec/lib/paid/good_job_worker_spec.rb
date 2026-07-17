# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/paid/good_job_worker"

RSpec.describe Paid::GoodJobWorker do
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
