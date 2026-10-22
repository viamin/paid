# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "open3"
require_relative "../../scripts/lib/rspec_coverage_shards"

RSpec.describe Paid::RspecCoverageShards do
  let(:root) { Dir.mktmpdir("coverage-shards") }
  let(:source) { File.join(root, "app", "example.rb") }

  around do |example|
    example.run
  ensure
    FileUtils.remove_entry(root)
  end

  before do
    FileUtils.mkdir_p(File.join(root, "app"))
    File.write(source, "value = 1\nvalue += 1\n")
  end

  def report(index, lines = [ 1, 0 ], name: "RSpec shard #{index}/2")
    path = File.join(root, "shard-#{index}.json")
    File.write(path, JSON.generate(name => { "coverage" => { source => { "lines" => lines } }, "timestamp" => Time.now.to_i }))
    path
  end

  # @spec TEST-SUITE-004
  it "accepts all distinct expected shard reports" do
    files = [ report(1), report(2) ]
    expect(described_class.validate(files: files, count: 2)).to eq(files)
  end

  # @spec TEST-SUITE-004
  it "rejects missing or duplicate shard reports" do
    expect { described_class.validate(files: [ report(1) ], count: 2) }.to raise_error(ArgumentError)
    first = report(1)
    duplicate = File.join(root, "duplicate.json")
    FileUtils.cp(first, duplicate)
    expect { described_class.validate(files: [ first, duplicate ], count: 2) }.to raise_error(ArgumentError)
  end

  # @spec TEST-SUITE-004
  it "rejects malformed, empty or unexpected shard payloads" do
    first = report(1)
    second = report(2, name: "RSpec shard 3/2")
    expect { described_class.validate(files: [ first, second ], count: 2) }.to raise_error(ArgumentError)
    File.write(second, "not json")
    expect { described_class.validate(files: [ first, second ], count: 2) }.to raise_error(ArgumentError)
    File.write(second, JSON.generate("RSpec shard 2/2" => { "coverage" => {} }))
    expect { described_class.validate(files: [ first, second ], count: 2) }.to raise_error(ArgumentError)
  end

  # @spec TEST-SUITE-005
  it "passes complementary partial reports and fails inadequate combined coverage" do
    first = report(1, [ 1, 0 ])
    second = report(2, [ 0, 1 ])
    script = File.expand_path("../../bin/rspec-coverage", __dir__)
    env = { "RSPEC_SHARD_COUNT" => "2", "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__) }
    _stdout, stderr, status = Open3.capture3(env, script, first, second, chdir: root)
    expect(status.success?).to be(true), stderr

    # A separate process cannot inherit the successful merge's cached coverage.
    FileUtils.rm_rf(File.join(root, "coverage"))
    second = report(2, [ 1, 0 ])
    _stdout, _stderr, status = Open3.capture3(env, script, first, second, chdir: root)
    expect(status.success?).to be(false)
  end
end
