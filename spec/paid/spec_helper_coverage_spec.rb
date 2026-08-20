# frozen_string_literal: true

require "rails_helper"
require "open3"

class SpecHelperCoverage < Pathname
end

RSpec.describe SpecHelperCoverage, :no_db do
  def run_spec_helper_probe(env)
    probe_script = <<~RUBY
      require "bundler/setup"
      require "rspec/core"
      require_relative "spec/spec_helper"
      if Object.const_defined?(:SimpleCov)
        SimpleCov.command_name("spec_helper_coverage_probe-\#{Process.pid}")
        SimpleCov.minimum_coverage 0
      end
      puts Object.const_defined?(:SimpleCov)
    RUBY

    Open3.capture3(env, "bundle", "exec", "ruby", "-e", probe_script, chdir: Rails.root.to_s)
  end

  # The decision logic is unit-tested in-process against the pure
  # SpecCoverageDecision module (fast). One subprocess spec below asserts the
  # wiring — that requiring spec_helper actually honors the decision.

  describe SpecCoverageDecision do
    it "disables coverage by default for intentional dbless runs" do
      expect(described_class.call(env: { "ALLOW_DBLESS_SPECS" => "true" })).to be(false)
    end

    it "still enables coverage when explicitly requested" do
      expect(described_class.call(env: { "ALLOW_DBLESS_SPECS" => "true", "COVERAGE" => "true" })).to be(true)
    end

    it "disables coverage when explicitly turned off" do
      expect(described_class.call(env: { "ALLOW_DBLESS_SPECS" => "false", "COVERAGE" => "false" })).to be(false)
    end

    it "enables coverage by default in a normal (non-dbless) run" do
      expect(described_class.call(env: {})).to be(true)
    end

    it "disables coverage during mutation sweeps, even when explicitly requested" do
      # Mutant loads spec_helper in its main process via the rspec integration,
      # so ::Mutant is defined at coverage-decision time. Whole-codebase line
      # coverage is meaningless for a scoped mutation run and previously failed
      # the job via the minimum_coverage gate, so SimpleCov must never start.
      expect(described_class.call(env: { "ALLOW_DBLESS_SPECS" => "true", "COVERAGE" => "true" }, mutant_defined: true)).to be(false)
    end
  end

  # Integration contract: requiring spec_helper.rb actually applies the
  # decision. Kept as a single subprocess assertion (not one per matrix case).
  it "wires SpecCoverageDecision into spec_helper (explicit request enables SimpleCov)" do
    stdout, stderr, status = run_spec_helper_probe(
      "ALLOW_DBLESS_SPECS" => "true",
      "COVERAGE" => "true"
    )

    expect(status.success?).to be(true), stderr
    expect(stderr).not_to include("SimpleCov.add_filter")
    expect(stdout.lines.first.to_s.strip).to eq("true")
  end
end
