# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "timeout"
require_relative "../support/exec_tmpdir"

RSpec.describe "bin/dev-temporal-worker" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  let(:dir) { Dir.mktmpdir("dev-temporal-worker", exec_tmpdir) }

  # @spec RAILS-CONTROL-PLANE-031
  around do |example|
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.cp(File.expand_path("../../bin/dev-temporal-worker", __dir__), script_path)
    example.run
  ensure
    FileUtils.remove_entry(dir)
  end

  it "recovers an isolated native crash and passes mode arguments unchanged" do
    write_worker(<<~RUBY)
      count = File.exist?("count") ? Integer(File.read("count")) : 0
      File.write("count", count + 1)
      abort "lost mode" unless ARGV == ["--mode=agent"]
      Process.kill("SEGV", Process.pid) if count.zero?
    RUBY
    _stdout, stderr, status = run_worker

    expect(status.exitstatus).to eq(0), stderr
    expect(File.read(File.join(dir, "count"))).to eq("2")
    expect(stderr).to include("attempt 1/3")
    expect(File.stat(File.join(dir, "log", "crashes")).mode & 0o777).to eq(0o700)
    reports = Dir.glob(File.join(dir, "log", "crashes", "temporal-agent-*.log"))
    expect(reports.size).to eq(1)
    expect(File.read(reports.first)).to include("[BUG] Segmentation fault")
  end

  it "stops after four native crashes within five minutes" do
    write_worker('File.open("count", "a") { |file| file.puts "run" }; exit 139')
    _stdout, stderr, status = run_worker

    expect(status.exitstatus).to eq(139)
    expect(File.readlines(File.join(dir, "count")).size).to eq(4)
    expect(stderr).to include("stopping automatic recovery")
  end

  it "surfaces ordinary failures without retrying" do
    write_worker('File.open("count", "a") { |file| file.puts "run" }; exit 1')
    _stdout, _stderr, status = run_worker

    expect(status.exitstatus).to eq(1)
    expect(File.readlines(File.join(dir, "count")).size).to eq(1)
  end

  it "does not launch a worker without a usable crash-report directory" do
    FileUtils.mkdir_p(File.join(dir, "log"))
    File.write(File.join(dir, "log", "crashes"), "not a directory")
    write_worker('File.write("started", "yes")')

    _stdout, _stderr, status = run_worker

    expect(status.success?).to be(false)
    expect(File.exist?(File.join(dir, "started"))).to be(false)
  end

  it "stops on INT before the booting worker has installed its signal handlers" do
    write_worker(<<~RUBY)
      Signal.trap("INT", "IGNORE")
      reader, writer = IO.pipe
      puts Process.pid
      $stdout.flush
      reader.read
      writer.close
    RUBY
    assert_interrupt_stops_worker
  end

  it "interrupts restart backoff promptly" do
    write_worker("exit 139")
    Open3.popen3(worker_env.merge("PAID_TEMPORAL_RESTART_DELAY_SECONDS" => "60"), script_path, chdir: dir, pgroup: true) do |stdin, _stdout, stderr, waiter|
      Timeout.timeout(5) do
        expect(stderr.gets).to include("restarting in 60s")
        Process.kill("INT", waiter.pid)
        expect(waiter.value.exitstatus).to eq(0)
      end
    ensure
      stdin.close unless stdin.closed?
      terminate_test_group(waiter.pid)
    end
  end

  %w[INT TERM].each do |signal|
    it "stops the child gracefully on #{signal} without restarting" do
      write_worker(<<~RUBY)
        trap("TERM") { exit 0 }
        trap("INT") { exit 0 }
        puts Process.pid
        $stdout.flush
        reader, writer = IO.pipe
        reader.read
        writer.close
      RUBY
      Open3.popen3(worker_env, script_path, "--mode=agent", chdir: dir, pgroup: true) do |stdin, stdout, stderr, waiter|
        Timeout.timeout(5) do
          child_pid = Integer(stdout.gets)
          Process.kill(signal, waiter.pid)
          expect(waiter.value.exitstatus).to eq(0), stderr.read
          expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
        end
      ensure
        stdin.close unless stdin.closed?
        terminate_test_group(waiter.pid)
      end
    end
  end

  def script_path
    File.join(dir, "bin", "dev-temporal-worker")
  end

  def assert_interrupt_stops_worker
    child_pid = nil
    Open3.popen3(worker_env, script_path, chdir: dir, pgroup: true) do |stdin, stdout, stderr, waiter|
      Timeout.timeout(5) do
        child_pid = Integer(stdout.gets)
        Process.kill("INT", waiter.pid)
        expect(waiter.value.exitstatus).to eq(0), stderr.read
        expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
      end
    ensure
      stdin.close unless stdin.closed?
      terminate_test_group(waiter.pid)
    end
  end

  def terminate_test_group(pid)
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  end

  def write_worker(source)
    File.write(File.join(dir, "bin", "temporal_worker"), source)
  end

  def worker_env
    { "PAID_TEMPORAL_RESTART_DELAY_SECONDS" => "0", "TEMPORAL_WORKER_MODE" => "agent" }
  end

  def run_worker
    Open3.capture3(worker_env, script_path, "--mode=agent", chdir: dir, rlimit_core: 0)
  end
end
