#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "fileutils"

ENV["RAILS_ENV"] ||= "production"
require_relative "../../config/environment"

require "json"

def benchmark_with_ci_data
  report = nil

  ActiveRecord::Base.transaction do
    PerformanceBenchmarks::CiSeedData.call
    report = PerformanceBenchmarks::Runner.call
    raise ActiveRecord::Rollback
  end

  report
end

options = {
  output: "tmp/performance/report.json",
  markdown: "tmp/performance/report.md",
  baseline: nil,
  fail_on_regression: false,
  seed_ci_data: false,
  required_metrics: []
}

OptionParser.new do |parser|
  parser.banner = "Usage: scripts/performance/benchmark.rb [options]"
  parser.on("--output PATH", "Write JSON report to PATH.") { |value| options[:output] = value }
  parser.on("--markdown PATH", "Write Markdown report to PATH.") { |value| options[:markdown] = value }
  parser.on("--baseline PATH", "Compare against a previous JSON baseline.") { |value| options[:baseline] = value }
  parser.on("--fail-on-regression", "Exit non-zero when budgets or baseline thresholds fail.") do
    options[:fail_on_regression] = true
  end
  parser.on("--seed-ci-data", "Create deterministic test records required by CI benchmarks.") do
    options[:seed_ci_data] = true
  end
  parser.on("--require-metrics x,y,z", Array, "Fail when any listed metric is skipped.") do |value|
    options[:required_metrics] = value
  end
end.parse!

report = if options[:seed_ci_data]
  benchmark_with_ci_data
else
  PerformanceBenchmarks::Runner.call
end
json = JSON.pretty_generate(report.to_h)

FileUtils.mkdir_p(File.dirname(options.fetch(:output)))
File.write(options.fetch(:output), "#{json}\n")

if options[:markdown].present?
  FileUtils.mkdir_p(File.dirname(options.fetch(:markdown)))
  File.write(options.fetch(:markdown), "#{report.to_markdown}\n")
end

puts "Wrote #{options.fetch(:output)}"
puts "Wrote #{options.fetch(:markdown)}" if options[:markdown].present?

if options[:baseline].present?
  baseline = JSON.parse(File.read(options.fetch(:baseline)))
  result = PerformanceBenchmarks::RegressionCheck.new(
    report: report.to_h,
    baseline: baseline,
    required_metrics: options.fetch(:required_metrics)
  ).call
  result.fetch(:failures).each { |failure| warn(failure) }
  exit(1) if options[:fail_on_regression] && !result.fetch(:passed)
end
