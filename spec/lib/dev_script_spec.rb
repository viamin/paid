# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "socket"
require "tmpdir"

RSpec.describe "bin/dev" do # rubocop:disable RSpec/DescribeClass
  let(:script_source) { File.expand_path("../../bin/dev", __dir__) }

  it "removes a stale Overmind socket before starting overmind" do
    Dir.mktmpdir("dev-script-spec", Dir.pwd) do |dir|
      script_path = prepare_script_fixture(dir)
      socket_path = create_stale_socket(dir)

      env = { "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}", "SKIP_DEV_CLEANUP" => "1" }
      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Removing stale Overmind socket...")
      expect(File.exist?(socket_path)).to be(false)
      expect(File.exist?(File.join(dir, "overmind-start-ran"))).to be(true)
    end
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def prepare_script_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    script_path = File.join(dir, "dev")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)

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

    script_path
  end

  def create_stale_socket(dir)
    socket_path = File.join(dir, ".overmind.sock")
    UNIXServer.open(socket_path) { |server| server.close }
    expect(File.socket?(socket_path)).to be(true)
    socket_path
  end
end
