# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../scripts/lib/rspec_shards"

RSpec.describe Paid::RspecShards do
  let(:root) { Dir.mktmpdir("rspec-shards") }

  around do |example|
    example.run
  ensure
    FileUtils.remove_entry(root)
  end

  def write_spec(path, size = 10)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), "x" * size)
  end

  # @spec TEST-SUITE-001
  it "assigns every eligible file exactly once and excludes separate suites" do
    files = %w[spec/models/a_spec.rb spec/models/b_spec.rb spec/requests/c_spec.rb spec/lib/d_spec.rb]
    files.each_with_index { |path, i| write_spec(path, (i + 1) * 10) }
    write_spec("spec/system/browser_spec.rb")
    write_spec("spec/performance/query_spec.rb")
    write_spec("spec/support/helper.rb")

    shards = described_class.partition(root: root, count: 3)

    expect(shards.flatten.sort).to eq(files.sort)
    expect(shards.flatten.uniq).to eq(shards.flatten)
    expect(described_class.partition(root: root, count: 3)).to eq(shards)
  end

  # @spec TEST-SUITE-001
  it "does not concentrate all large files in one shard" do
    %w[a b c d].each { |name| write_spec("spec/#{name}_spec.rb", 100) }
    shards = described_class.partition(root: root, count: 2)
    expect(shards.map(&:size)).to eq([ 2, 2 ])
  end

  # @spec TEST-SUITE-002
  it "rejects nonpositive shard counts" do
    expect { described_class.partition(root: root, count: 0) }.to raise_error(ArgumentError)
    expect { described_class.partition(root: root, count: -1) }.to raise_error(ArgumentError)
  end

  # @spec TEST-SUITE-002
  it "rejects an out-of-range index and an empty selected shard" do
    write_spec("spec/a_spec.rb")
    expect { described_class.select(root: root, count: 2, index: -1) }.to raise_error(ArgumentError)
    expect { described_class.select(root: root, count: 2, index: 2) }.to raise_error(ArgumentError)
    expect { described_class.select(root: root, count: 2, index: 1) }.to raise_error(ArgumentError, /empty/)
  end
end
