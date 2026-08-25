# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

RSpec.describe "bin/docker-entrypoint" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  # @spec PROMPT-DEFAULT-SYNC-008
  it "prepares and synchronizes the database before starting a Rails server" do
    with_entrypoint_fixture do |dir, entrypoint|
      _stdout, stderr, status = Open3.capture3(entrypoint, "./bin/rails", "server", chdir: dir)

      expect(status.success?).to be(true), stderr
      expect(File.readlines(File.join(dir, "calls.log"), chomp: true)).to eq([
        "db:prepare prompts:sync_defaults",
        "server"
      ])
    end
  end

  # @spec PROMPT-DEFAULT-SYNC-008
  it "does not start the server when prompt synchronization fails" do
    with_entrypoint_fixture(sync_exit_status: 1) do |dir, entrypoint|
      _stdout, _stderr, status = Open3.capture3(entrypoint, "./bin/rails", "server", chdir: dir)

      expect(status.success?).to be(false)
      expect(File.readlines(File.join(dir, "calls.log"), chomp: true)).to eq([
        "db:prepare prompts:sync_defaults"
      ])
    end
  end

  def with_entrypoint_fixture(sync_exit_status: 0)
    Dir.mktmpdir("docker-entrypoint-spec", exec_tmpdir) do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      entrypoint = File.join(dir, "bin", "docker-entrypoint")
      FileUtils.cp(File.expand_path("../../bin/docker-entrypoint", __dir__), entrypoint)
      FileUtils.chmod("+x", entrypoint)
      write_rails_stub(dir, sync_exit_status:)
      yield dir, entrypoint
    end
  end

  def write_rails_stub(dir, sync_exit_status:)
    path = File.join(dir, "bin", "rails")
    File.write(path, <<~BASH)
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "#{dir}/calls.log"
      [ "$*" = "db:prepare prompts:sync_defaults" ] && exit #{sync_exit_status}
      exit 0
    BASH
    FileUtils.chmod("+x", path)
  end
end
