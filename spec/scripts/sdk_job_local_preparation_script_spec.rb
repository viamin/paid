# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "pathname"
require "shellwords"
require_relative "../support/exec_tmpdir"

class SdkJobLocalPreparationScript
end

RSpec.describe SdkJobLocalPreparationScript do # @spec RUST-SDK-BUILD-014
  include ExecTmpdir

  let(:directory) { Pathname(Dir.mktmpdir("sdk-preparation", exec_tmpdir)).realpath }
  let(:workspace) { directory.join("workspace") }
  let(:marker) { directory.join("curl-called") }
  let(:script) { directory.join("prepare.sh") }

  around do |example|
    workspace.mkpath
    directory.join("bin").mkpath
    directory.join("bin/curl").write("#!/bin/sh\nprintf called > \"$CURL_MARKER\"\nexit 77\n")
    directory.join("bin/curl").chmod(0o755)
    prepare_script_fixture
    example.run
  ensure
    FileUtils.remove_entry(directory)
  end

  it "refuses a different root before creating directories or invoking curl" do
    other = directory.join("other")
    other.mkpath

    expect_refusal("WORK_ROOT" => other.to_s)

    expect(other.children).to be_empty
  end

  %w[downloads ruby tools/protoc toolchain-inputs toolchain unpack cargo target source.before.sha].each do |path|
    it "refuses an occupied #{path} without changing it" do
      reserved = workspace.join(path)
      reserved.dirname.mkpath
      reserved.write("existing job data")

      expect_refusal

      expect(reserved.read).to eq("existing job data")
    end
  end

  %w[ruby tools].each do |path|
    it "refuses a symlinked #{path} without writing through it" do
      outside = directory.join("outside")
      outside.mkpath
      File.symlink(outside, workspace.join(path))

      expect_refusal

      expect(outside.children).to be_empty
    end
  end

  it "refuses a dangling reserved symlink" do
    File.symlink(directory.join("absent"), workspace.join("ruby"))

    expect_refusal

    expect(directory.join("absent")).not_to exist
  end

  it "refuses a non-directory tools parent" do
    workspace.join("tools").write("existing job data")

    expect_refusal

    expect(workspace.join("tools").read).to eq("existing job data")
  end

  it "permits a checkout in the assigned root and refuses a repeated preparation" do
    workspace.join(".git").mkpath
    workspace.join("README.md").write("existing Paid checkout")

    _stdout, _stderr, status = run_script

    expect(status.exitstatus).to eq(77)
    expect(marker).to exist
    expect(workspace.join("README.md").read).to eq("existing Paid checkout")
    marker.unlink
    expect_refusal
  end

  def prepare_script_fixture
    source = File.read(File.expand_path("../../docs/intent/isolated-rust-sdk-build/job-local-baseline/prepare-inputs.sh", __dir__))
    # Rebase only the assigned-root constant into this owned test directory.
    # The unchanged script is separately exercised at /workspace in its agent image.
    raise "Assigned-root constant missing" unless source.include?("assigned_root=/workspace\n")

    script.write(source.sub("assigned_root=/workspace\n", "assigned_root=#{Shellwords.escape(workspace.to_s)}\n"))
  end

  def run_script(overrides = {})
    environment = { "WORK_ROOT" => workspace.to_s, "CURL_MARKER" => marker.to_s,
      "PATH" => "#{directory.join('bin')}:#{ENV.fetch('PATH')}" }.merge(overrides)
    Open3.capture3(environment, "sh", script.to_s)
  end

  def expect_refusal(overrides = {})
    before = workspace_snapshot
    _stdout, _stderr, status = run_script(overrides)
    expect(status.success?).to be(false)
    expect(status.exitstatus).not_to eq(77)
    expect(marker).not_to exist
    expect(workspace_snapshot).to eq(before)
  end

  def workspace_snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: workspace).reject { |path| path == "." }.sort.map do |path|
      entry = workspace.join(path)
      value = if entry.symlink?
        [ "symlink", entry.readlink.to_s ]
      elsif entry.directory?
        [ "directory" ]
      else
        [ "file", entry.binread ]
      end
      [ path, value ]
    end
  end
end
