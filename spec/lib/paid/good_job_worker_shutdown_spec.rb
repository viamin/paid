# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "timeout"

RSpec.describe "GoodJob worker shutdown" do # rubocop:disable RSpec/DescribeClass
  let(:root) { File.expand_path("../../..", __dir__) }
  let(:worker_source) do
    <<~RUBY
      require "active_support/core_ext/object/blank"
      require #{File.join(root, "lib/paid/good_job_worker").inspect}
      require #{File.join(root, "lib/paid/good_job_worker/health_snapshot").inspect}
      require #{File.join(root, "lib/paid/worker_readiness").inspect}
      module GoodJob
        def self.capsule = self
        def self.start = nil
        def self.shutdown(timeout:)
          puts "shutdown-entered"
          $stdout.flush
          reader, writer = IO.pipe
          reader.read
          writer.close
        end
      end
      shutdown_timeout = 1
      forced_exit_timeout = Float(ENV.fetch("SHUTDOWN_TEST_TIMEOUT"))
      health_recovery = nil
      path = #{File.join(root, "bin/jobs").inspect}
      source = File.read(path)
      start = source.index("\nshutdown = ") + 1
      finish = source.index("\nlast_health_check_at =", start)
      eval(source[start...finish], binding, path)
      if ENV.fetch("SHUTDOWN_TEST_TRIGGER") == "signal"
        puts "ready-for-signal"
        $stdout.flush
        STDIN.gets
      end
      health_recovery.recover
      puts "health-recovery-returned"
      $stdout.flush
      STDIN.read
    RUBY
  end

  # @spec RAILS-CONTROL-PLANE-030
  it "forces exit when health-triggered graceful shutdown blocks" do
    with_worker(timeout: 0.1) do |readiness, stdout, stderr, waiter|
      expect_shutdown_started(stdout)
      expect(waiter.value.exitstatus).to eq(1)
      expect(File.exist?(readiness)).to be(false)
      expect(stderr.read).to include("did not exit within 0.1s, forcing exit")
    end
  end

  # @spec RAILS-CONTROL-PLANE-030 RAILS-CONTROL-PLANE-032
  it "forces exit on a signal after health recovery started shutdown" do
    with_worker(timeout: 60) do |_readiness, stdout, stderr, waiter|
      expect_shutdown_started(stdout)
      Process.kill("TERM", waiter.pid)
      expect(waiter.value.exitstatus).to eq(1)
      expect(stderr.read).to include("during shutdown, forcing GoodJob worker exit")
    end
  end

  # @spec RAILS-CONTROL-PLANE-030
  it "preserves the graceful deadline when health degrades during signal shutdown" do
    with_worker(timeout: 1, trigger: "signal") do |_readiness, stdout, stderr, waiter, stdin|
      expect(stdout.each_line.find { |line| line == "ready-for-signal\n" }).to eq("ready-for-signal\n")
      Process.kill("TERM", waiter.pid)
      expect_shutdown_started(stdout)
      stdin.puts("check health")
      expect(stdout.gets).to eq("health-recovery-returned\n")
      expect(waiter.value.exitstatus).to eq(1)
      expect(stderr.read).to include("did not exit within 1.0s, forcing exit")
    end
  end

  def expect_shutdown_started(stdout)
    expect(stdout.each_line.find { |line| line == "shutdown-entered\n" }).to eq("shutdown-entered\n")
  end

  def with_worker(timeout:, trigger: "health")
    Dir.mktmpdir("good-job-shutdown") do |dir|
      readiness = File.join(dir, "ready")
      env = { "WORKER_READINESS_FILE" => readiness, "SHUTDOWN_TEST_TIMEOUT" => timeout.to_s,
              "SHUTDOWN_TEST_TRIGGER" => trigger }
      Open3.popen3(env, RbConfig.ruby, "-e", worker_source) do |stdin, stdout, stderr, waiter|
        Timeout.timeout(5) { yield readiness, stdout, stderr, waiter, stdin }
      ensure
        stdin.close unless stdin.closed?
        Process.kill("KILL", waiter.pid) if waiter.alive?
      end
    end
  end
end
