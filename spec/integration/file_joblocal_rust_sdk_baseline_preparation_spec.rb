# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

RSpec.describe File, :no_db do
  describe "job-local Rust SDK baseline preparation" do
    let(:directory) { Pathname(Dir.mktmpdir("sdk-preparation")) }
    let(:workspace) { directory.join("workspace") }
    let(:script) { Rails.root.join("docs/intent/isolated-rust-sdk-build/job-local-baseline/prepare-inputs.sh") }
    let(:test_script) { directory.join("prepare-inputs.sh") }

    around do |example|
      workspace.mkpath
      write_test_script!
      example.run
    ensure
      FileUtils.remove_entry(directory) if directory.exist?
    end

    # @spec RUST-SDK-BUILD-013
    it "refuses an alternate workspace before downloading" do
      Dir.mktmpdir("alternate-workspace") do |alternate_workspace|
        _stdout, stderr, status, curl_invoked = run_preparation(script:, work_root: alternate_workspace)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("WORK_ROOT must be the assigned /workspace job directory")
        expect(curl_invoked).to be(false)
      end
    end

    # @spec RUST-SDK-BUILD-013
    it "refuses an occupied reserved source path before downloading" do
      workspace.join("ruby").mkpath

      _stdout, stderr, status, curl_invoked = run_preparation

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("refusing occupied reserved path: #{workspace}/ruby")
      expect(curl_invoked).to be(false)
    end

    # @spec RUST-SDK-BUILD-013
    it "refuses a symbolic-link reserved source path before downloading" do
      Dir.mktmpdir("ruby-target") do |target|
        described_class.symlink(target, workspace.join("ruby"))

        _stdout, stderr, status, curl_invoked = run_preparation

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("refusing occupied reserved path: #{workspace}/ruby")
        expect(curl_invoked).to be(false)
      end
    end

    # @spec RUST-SDK-BUILD-013
    it "claims preparation before creating recipe directories" do
      workspace.join(".prepare-inputs.lock").mkpath

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

    def run_preparation(script: test_script, work_root: workspace)
      Dir.mktmpdir("prepare-inputs-bin") do |bin|
        curl_log = described_class.join(bin, "curl-invoked")
        curl_path = described_class.join(bin, "curl")
        described_class.write(curl_path, "#!/bin/sh\ntouch \"$CURL_LOG\"\nexit 77\n")
        FileUtils.chmod("u+x", curl_path)
        result = Open3.capture3(
          { "WORK_ROOT" => work_root.to_s, "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "CURL_LOG" => curl_log },
          "sh", script.to_s
        )
        [ *result, described_class.exist?(curl_log) ]
      end
    end

    def write_test_script!
      source = script.read
      assigned_workspace = Shellwords.escape(workspace.to_s)
      test_script.write(source.sub('test "$WORK_ROOT" = /workspace', "test \"$WORK_ROOT\" = #{assigned_workspace}"))
    end
  end
end
