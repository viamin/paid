# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe File, :no_db do
  describe "job-local Rust SDK baseline preparation" do
  let(:workspace) { "/workspace" }
  let(:script) { Rails.root.join("docs/intent/isolated-rust-sdk-build/job-local-baseline/prepare-inputs.sh") }
  let(:reserved_paths) do
    %w[downloads ruby tools tools/protoc toolchain-inputs toolchain unpack cargo target source.before.sha]
  end

  around do |example|
    owns_recipe_state = false
    refuse_if_recipe_state_exists!
    owns_recipe_state = true
    example.run
  ensure
    remove_recipe_state! if owns_recipe_state
  end

  # @spec RUST-SDK-BUILD-013
  it "refuses an alternate workspace before downloading" do
    Dir.mktmpdir("alternate-workspace") do |alternate_workspace|
      _stdout, stderr, status, curl_invoked = run_preparation(work_root: alternate_workspace)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("WORK_ROOT must be the assigned /workspace job directory")
      expect(curl_invoked).to be(false)
    end
  end

  # @spec RUST-SDK-BUILD-013
  it "refuses an occupied reserved source path before downloading" do
    FileUtils.mkdir(described_class.join(workspace, "ruby"))

    _stdout, stderr, status, curl_invoked = run_preparation

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("refusing occupied reserved path: /workspace/ruby")
    expect(curl_invoked).to be(false)
  end

  # @spec RUST-SDK-BUILD-013
  it "refuses a symbolic-link reserved source path before downloading" do
    Dir.mktmpdir("ruby-target") do |target|
      described_class.symlink(target, described_class.join(workspace, "ruby"))

      _stdout, stderr, status, curl_invoked = run_preparation

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("refusing occupied reserved path: /workspace/ruby")
      expect(curl_invoked).to be(false)
    end
  end

  # @spec RUST-SDK-BUILD-013
  it "claims preparation before creating recipe directories" do
    FileUtils.mkdir(described_class.join(workspace, ".prepare-inputs.lock"))

    _stdout, stderr, status, curl_invoked = run_preparation

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("preparation is already in progress or was not cleaned up")
    expect(curl_invoked).to be(false)
  end

  # @spec RUST-SDK-BUILD-013
  it "reaches the bounded download command from a fresh assigned workspace" do
    _stdout, _stderr, status, curl_invoked = run_preparation

    expect(status.exitstatus).to eq(77)
    expect(curl_invoked).to be(true)
  end

  private

  def run_preparation(work_root: workspace)
    Dir.mktmpdir("prepare-inputs-bin") do |bin|
      curl_log = described_class.join(bin, "curl-invoked")
      curl_path = described_class.join(bin, "curl")
      described_class.write(curl_path, "#!/bin/sh\ntouch \"$CURL_LOG\"\nexit 77\n")
      FileUtils.chmod("u+x", curl_path)
      result = Open3.capture3(
        { "WORK_ROOT" => work_root, "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "CURL_LOG" => curl_log },
        "sh", script.to_s
      )
      [ *result, described_class.exist?(curl_log) ]
    end
  end

  def refuse_if_recipe_state_exists!
    existing = (reserved_paths + [ ".prepare-inputs.lock" ]).select do |path|
      described_class.exist?(described_class.join(workspace, path)) || described_class.symlink?(described_class.join(workspace, path))
    end
    raise "job-local recipe state already exists: #{existing.join(', ')}" if existing.any?
  end

  def remove_recipe_state!
    reserved_paths.reverse_each do |path|
      full_path = described_class.join(workspace, path)
      FileUtils.remove_entry(full_path) if described_class.exist?(full_path) || described_class.symlink?(full_path)
    end
    lock_path = described_class.join(workspace, ".prepare-inputs.lock")
    FileUtils.remove_entry(lock_path) if described_class.exist?(lock_path) || described_class.symlink?(lock_path)
  end
  end
end
