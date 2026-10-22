# frozen_string_literal: true

require "json"

module Paid
  module RspecCoverageShards
    module_function

    # @spec TEST-SUITE-004
    def validate(files:, count:)
      raise ArgumentError, "expected #{count} coverage reports" unless count.positive? && files.size == count

      names = files.map { |file| shard_name(file) }
      expected = (1..count).map { |index| "RSpec shard #{index}/#{count}" }
      raise ArgumentError, "coverage shards missing, duplicate or unexpected" unless names.sort == expected.sort

      files
    rescue JSON::ParserError => error
      raise ArgumentError, "malformed coverage report: #{error.message}"
    end

    # @spec TEST-SUITE-005
    def collate(files:, count:)
      validate(files:, count:)
      require "simplecov"
      SimpleCov.collate(files, "rails", ignore_timeout: true) do
        minimum_coverage 80
        skip "/spec/"
        skip "/config/"
        skip "/vendor/"
      end
    end

    def shard_name(file)
      results = JSON.parse(File.read(file))
      raise ArgumentError, "invalid coverage report #{file}" unless results.is_a?(Hash)

      names = results.keys.grep(/\ARSpec shard /)
      raise ArgumentError, "expected one shard identity in #{file}" unless names.one?

      payload = results.fetch(names.first)
      coverage = payload.is_a?(Hash) && payload["coverage"]
      raise ArgumentError, "empty coverage report #{file}" unless coverage.is_a?(Hash) && !coverage.empty?

      names.first
    end
  end
end
