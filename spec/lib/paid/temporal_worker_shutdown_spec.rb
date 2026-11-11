# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"
require_relative "../../../lib/paid/temporal_worker_shutdown"

RSpec.describe Paid::TemporalWorkerShutdown do # @spec TEMPORAL-ORCHESTRATION-013
  let(:worker_source) do
    <<~RUBY
      Paid::WorkerReadiness.mark_ready!
      Paid::TemporalWorkerShutdown.install(
        request_shutdown: ->(reason:) { puts "cancelled:\#{reason}"; $stdout.flush },
        forced_exit_timeout: 10
      )
      puts "ready"
      $stdout.flush
      STDIN.read
    RUBY
  end

  it "cancels outside trap context, clears readiness, and forces exit on a second signal" do
    with_shutdown_worker(worker_source) do |readiness_file, stdout, stderr, waiter|
      assert_shutdown(readiness_file, stdout, stderr, waiter)
    end
  end

  it "forces exit when the cancellation callback blocks" do
    with_shutdown_worker(blocked_worker_source) do |readiness_file, stdout, stderr, waiter|
      Timeout.timeout(5) do
        expect(stdout.gets).to eq("ready\n")
        Process.kill("TERM", waiter.pid)
        expect(waiter.value.exitstatus).to eq(1)
        expect(File.exist?(readiness_file)).to be(false)
        expect(stderr.read).to include("did not exit within")
      end
    end
  end

  def blocked_worker_source
    <<~RUBY
      Paid::WorkerReadiness.mark_ready!
      Paid::TemporalWorkerShutdown.install(
        request_shutdown: ->(reason:) { sleep 10 },
        forced_exit_timeout: 0.2
      )
      puts "ready"
      $stdout.flush
      STDIN.read
    RUBY
  end

  def with_shutdown_worker(source)
    Dir.mktmpdir("temporal-worker-signal") do |dir|
      readiness_file = File.join(dir, "ready")
      env = { "WORKER_READINESS_FILE" => readiness_file }
      lib_path = File.expand_path("../../../lib", __dir__)
      Open3.popen3(env, RbConfig.ruby, "-I#{lib_path}", "-rtmpdir", "-ractive_support/core_ext/object/blank",
        "-rpaid/worker_readiness", "-rpaid/temporal_worker_shutdown", "-e", source) do |stdin, stdout, stderr, waiter|
        yield readiness_file, stdout, stderr, waiter
      ensure
        stdin.close unless stdin.closed?
        Process.kill("KILL", waiter.pid) if waiter.alive?
      end
    end
  end

  def assert_shutdown(readiness_file, stdout, stderr, waiter)
    Timeout.timeout(5) do
      expect(stdout.gets).to eq("ready\n")
      expect(File.exist?(readiness_file)).to be(true)

      Process.kill("TERM", waiter.pid)
      expect(stdout.gets).to eq("cancelled:TERM received\n")
      expect(File.exist?(readiness_file)).to be(false)

      Process.kill("TERM", waiter.pid)
      expect(waiter.value.exitstatus).to eq(1)
      expect(stderr.read).to include("shutting down Temporal workers gracefully")
    end
  end
end
