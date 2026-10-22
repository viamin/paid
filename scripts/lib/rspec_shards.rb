# frozen_string_literal: true

module Paid
  module RspecShards
    module_function

    # @spec TEST-SUITE-001
    def partition(root:, count:)
      raise ArgumentError, "shard count must be positive" unless count.positive?

      shards = Array.new(count) { [] }
      sizes = Array.new(count, 0)
      files = Dir.glob("spec/**/*_spec.rb", base: root)
        .reject { |path| path.start_with?("spec/system/", "spec/performance/") }
        .sort_by { |path| [ -File.size(File.join(root, path)), path ] }
      files.each do |path|
        index = sizes.each_index.min_by { |i| [ sizes[i], i ] }
        shards[index] << path
        sizes[index] += File.size(File.join(root, path))
      end
      shards.map(&:sort)
    end

    # @spec TEST-SUITE-002
    def select(root:, count:, index:)
      raise ArgumentError, "shard index out of range" unless index.between?(0, count - 1)

      partition(root:, count:).fetch(index).tap do |files|
        raise ArgumentError, "selected shard is empty" if files.empty?
      end
    end
  end
end
