# frozen_string_literal: true

require "rails_helper"
require "open3"

# bin/update reaches every public package registry it knows about, so these
# examples cover the argument contract that is decided before any network call.
# The resolution and rewrite logic it orchestrates is covered by
# spec/lib/upstream_registries_spec.rb and
# spec/config/toolchain_pins_spec.rb.
RSpec.describe "bin/update", :no_db do # rubocop:disable RSpec/DescribeClass
  def run(*args)
    Open3.capture3(RbConfig.ruby, Rails.root.join("bin/update").to_s, *args, chdir: Rails.root.to_s)
  end

  # @spec TOOLCHAIN-PIN-051
  describe "--help" do
    it "documents the report-only mode alongside the writing modes" do
      stdout, _stderr, status = run("--help")

      expect(status).to be_success
      expect(stdout).to include("--check")
      expect(stdout).to include("Report available updates without writing any files")
      expect(stdout).to include("--lockfiles")
      expect(stdout).to include("--skip-age-check")
    end
  end

  describe "argument validation" do
    it "rejects an unknown argument instead of running a partial update" do
      _stdout, stderr, status = run("--definitely-not-a-flag")

      expect(status).not_to be_success
      expect(stderr).to include("Unknown arguments")
    end

    # bundle and yarn write their own lockfiles, so there is no honest
    # report-only run that also updates them.
    it "refuses to combine report-only mode with lockfile updates" do
      _stdout, stderr, status = run("--check", "--lockfiles")

      expect(status).not_to be_success
      expect(stderr).to include("--check cannot be combined with --lockfiles")
    end
  end
end
