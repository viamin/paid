# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "socket"
require "tmpdir"
require_relative "../support/exec_tmpdir"

RSpec.describe "bin/dev" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir
  let(:script_source) { File.expand_path("../../bin/dev", __dir__) }

  it "removes a stale Overmind socket before starting overmind" do
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      socket_path = create_stale_socket(dir)

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock"
      }
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Removing stale Overmind socket...")
      expect(File.exist?(socket_path)).to be(false)
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(true)
    end
  end

  it "removes stale tmux sockets and writes diagnostics logs" do
    Dir.mktmpdir("dev-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      tmux_socket_dir = File.join(dir, "tmux")
      FileUtils.mkdir_p(tmux_socket_dir)
      stale_tmux_socket = create_socket(File.join(tmux_socket_dir, "overmind-#{File.basename(dir)}-stale"))

      env = {
        "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
        "SKIP_DEV_CLEANUP" => "1",
        "OVERMIND_SOCKET" => ".overmind.sock",
        "DEV_SUPERVISOR_TMUX_SOCKET_DIR" => tmux_socket_dir
      }
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(stale_tmux_socket)).to be(false)
      expect(File.exist?(File.join(dir, "log", "dev-update", "tmux.log"))).to be(true)
      expect(Dir.glob(File.join(dir, "log", "dev-update", "diagnostics", "*bin-dev-before-start.log"))).not_to be_empty
    end
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def prepare_script_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "stubbin"))
    FileUtils.mkdir_p(File.join(dir, "bin", "lib"))
    FileUtils.mkdir_p(File.join(dir, "config"))

    script_path = File.join(dir, "bin", "dev")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)
    FileUtils.cp(File.expand_path("../../bin/lib/dev_supervisor.sh", __dir__), File.join(dir, "bin", "lib", "dev_supervisor.sh"))
    FileUtils.cp(File.expand_path("../../config/overmind.tmux.conf", __dir__), File.join(dir, "config", "overmind.tmux.conf"))

    write_executable(
      File.join(dir, "stubbin", "overmind"),
      <<~BASH
        #!/usr/bin/env bash
        case "$1" in
          status)
            exit 1
            ;;
          start)
            touch "#{dir}/overmind-start-ran"
            exit 0
            ;;
          *)
            echo "unexpected overmind command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "tmux"),
      <<~BASH
        #!/usr/bin/env bash
        if [ "$1" = "-S" ] && [ "$3" = "ls" ]; then
          exit 1
        fi
        echo "unexpected tmux command: $*" >&2
        exit 1
      BASH
    )

    script_path
  end

  def create_stale_socket(dir)
    socket_path = File.join(dir, ".overmind.sock")
    create_socket(socket_path)
  end

  def create_socket(path)
    UNIXServer.open(path) { |server| server.close }
    expect(File.socket?(path)).to be(true)
    path
  end
end
