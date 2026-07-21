# frozen_string_literal: true

require "rails_helper"
require "open3"

class SpecHelperCoverage < Pathname
end

RSpec.describe SpecHelperCoverage, :no_db do
  let(:probe_script) do
    <<~RUBY
      require "bundler/setup"
      require "rspec/core"
      require_relative "spec/spec_helper"
      if Object.const_defined?(:SimpleCov)
        SimpleCov.command_name("spec_helper_coverage_probe-\#{Process.pid}")
        SimpleCov.minimum_coverage 0
      end
      puts Object.const_defined?(:SimpleCov)
    RUBY
  end

  it "disables coverage by default for intentional dbless runs" do
    stdout, stderr, status = Open3.capture3(
      {
        "ALLOW_DBLESS_SPECS" => "true",
        "COVERAGE" => nil
      },
      "bundle", "exec", "ruby", "-e", probe_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.lines.first.to_s.strip).to eq("false")
  end

  it "still enables coverage when explicitly requested" do
    stdout, stderr, status = Open3.capture3(
      {
        "ALLOW_DBLESS_SPECS" => "true",
        "COVERAGE" => "true"
      },
      "bundle", "exec", "ruby", "-e", probe_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.lines.first.to_s.strip).to eq("true")
  end

  it "disables coverage when explicitly turned off" do
    stdout, stderr, status = Open3.capture3(
      {
        "ALLOW_DBLESS_SPECS" => "false",
        "COVERAGE" => "false"
      },
      "bundle", "exec", "ruby", "-e", probe_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.lines.first.to_s.strip).to eq("false")
  end
end
