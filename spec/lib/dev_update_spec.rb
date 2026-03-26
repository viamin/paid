# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "socket"
require "tmpdir"
require "timeout"

RSpec.describe "bin/dev-update" do # rubocop:disable RSpec/DescribeClass
  let(:script_source) { File.expand_path("../../bin/dev-update", __dir__) }

  it "removes a stale Overmind socket before restarting the dev environment" do
    Dir.mktmpdir("dev-update-spec") do |dir|
      script_path = prepare_script_fixture(dir)
      socket_path = create_stale_socket(dir)

      env = { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}" }
      stdout, stderr, status = Open3.capture3(env, script_path, "--full", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.exist?(socket_path)).to be(false)
      expect(File.exist?(File.join(dir, "overmind-quit-ran"))).to be(false)
      expect(File.exist?(File.join(dir, "setup-ran"))).to be(true)
      expect(stdout).to include("Overmind is healthy after restart.")

      Timeout.timeout(5) do
        sleep 0.1 until File.exist?(File.join(dir, "dev-ran"))
      end
    end
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def prepare_script_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    script_path = File.join(dir, "bin", "dev-update")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)

    write_executable(
      File.join(dir, "bin", "setup"),
      <<~BASH
        #!/usr/bin/env bash
        touch "#{dir}/setup-ran"
      BASH
    )

    write_executable(
      File.join(dir, "bin", "dev"),
      <<~BASH
        #!/usr/bin/env bash
        touch "#{dir}/dev-ran"
        touch "#{dir}/overmind-running"
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        case "$1" in
          rev-parse)
            echo "main"
            ;;
          pull)
            exit 0
            ;;
          *)
            echo "unexpected git command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "overmind"),
      <<~BASH
        #!/usr/bin/env bash
        case "$1" in
          status)
            [ -e "#{dir}/overmind-running" ]
            exit $?
            ;;
          quit)
            touch "#{dir}/overmind-quit-ran"
            exit 0
            ;;
          *)
            echo "unexpected overmind command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    script_path
  end

  def create_stale_socket(dir)
    socket_path = File.join(dir, ".overmind.sock")
    UNIXServer.open(socket_path) { |server| server.close }
    expect(File.socket?(socket_path)).to be(true)
    socket_path
  end
end
