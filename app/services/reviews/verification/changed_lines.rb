# frozen_string_literal: true

module Reviews
  module Verification
    # Index of the right-side (new version) line ranges touched by a pull
    # request, parsed from the unified diff patches GitHub returns per file.
    # Used to validate that every inline comment anchors to a line GitHub will
    # accept for the pinned head (#3898).
    #
    # Files without a parseable patch (binary, renamed without content change)
    # are still recorded as changed so path checks succeed, but no line is a
    # valid anchor for them.
    #
    # @spec REVIEW-VERIFY-008
    class ChangedLines
      HUNK_HEADER = /^@@ -\d+(?:,\d+)? \+(?<start>\d+)(?:,(?<count>\d+))? @@/

      # @param files [Array<Hash>] entries shaped like
      #   GithubClient#detailed_pull_request_files (+:filename+, +:patch+)
      # @return [ChangedLines]
      def self.from_files(files)
        ranges = files.to_h do |file|
          [ file[:filename], hunk_ranges(file[:patch]) ]
        end
        new(ranges)
      end

      def self.hunk_ranges(patch)
        return [] if patch.blank?

        patch.each_line.filter_map do |line|
          match = HUNK_HEADER.match(line)
          next unless match

          start = match[:start].to_i
          count = (match[:count] || 1).to_i
          next if count.zero?

          start..(start + count - 1)
        end
      end
      private_class_method :hunk_ranges

      # @param ranges [Hash{String => Array<Range>}] filename => right-side hunk ranges
      def initialize(ranges)
        @ranges = ranges.freeze
      end

      def changed_file?(path)
        @ranges.key?(path)
      end

      def changed_file_names
        @ranges.keys
      end

      def valid_line?(path, line)
        return false unless line.is_a?(Integer) && line.positive?

        @ranges.fetch(path, []).any? { |range| range.cover?(line) }
      end

      def empty?
        @ranges.empty?
      end
    end
  end
end
