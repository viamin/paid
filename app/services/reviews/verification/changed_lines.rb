# frozen_string_literal: true

module Reviews
  module Verification
    # Index of changed right-side (new version) line ranges touched by a pull
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
      HUNK_HEADER = /^@@ -\d+(?:,\d+)? \+(?<start>\d+)(?:,\d+)? @@/

      # @param files [Array<Hash>] entries shaped like
      #   GithubClient#detailed_pull_request_files (+:filename+, +:patch+)
      # @return [ChangedLines]
      def self.from_files(files)
        ranges = files.to_h do |file|
          [ file[:filename], changed_ranges(file[:patch]) ]
        end
        new(ranges)
      end

      def self.changed_ranges(patch)
        return [] if patch.blank?

        changed_lines = []
        right_line = nil

        patch.each_line do |line|
          if (match = HUNK_HEADER.match(line))
            right_line = match[:start].to_i
          elsif right_line && line.start_with?("+")
            changed_lines << right_line
            right_line += 1
          elsif right_line && !line.start_with?("-", "\\")
            right_line += 1
          end
        end

        changed_lines.chunk_while { |previous, current| current == previous + 1 }
          .map { |lines| lines.first..lines.last }
      end
      private_class_method :changed_ranges

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
