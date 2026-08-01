# frozen_string_literal: true

module Lid
  class CoherenceReport
    Result = Data.define(
      :status,
      :summary_line,
      :reverse_orphans,
      :uncovered_specs,
      :broken_arrow_refs,
      :stale_arrows,
      :untagged_code_files,
      :untagged_test_files,
      :report_excerpt
    ) do
      def to_h
        {
          "status" => status,
          "summary_line" => summary_line,
          "reverse_orphans" => reverse_orphans,
          "uncovered_specs" => uncovered_specs,
          "broken_arrow_refs" => broken_arrow_refs,
          "stale_arrows" => stale_arrows,
          "untagged_code_files" => untagged_code_files,
          "untagged_test_files" => untagged_test_files,
          "report_excerpt" => report_excerpt
        }
      end

      def failed?
        status == "failed"
      end
    end

    def self.parse(output)
      new(output).parse
    end

    def initialize(output)
      @output = output.to_s
    end

    def parse
      counts = {
        reverse_orphans: capture_count(/Reverse orphans \((\d+)\)/),
        uncovered_specs: capture_count(/Uncovered \[ \] specs \((\d+)\)/),
        broken_arrow_refs: @output.scan(/^\s+\[(?:MISSING|BROKEN)\]/).size,
        stale_arrows: stale_arrow_count,
        untagged_code_files: capture_count(/Untagged code files \((\d+)\)/),
        untagged_test_files: capture_count(/Untagged test files \((\d+)\)/)
      }
      failing = counts.values.sum

      Result.new(
        status: failing.positive? ? "failed" : "passed",
        summary_line: summary_line(counts),
        reverse_orphans: counts[:reverse_orphans],
        uncovered_specs: counts[:uncovered_specs],
        broken_arrow_refs: counts[:broken_arrow_refs],
        stale_arrows: counts[:stale_arrows],
        untagged_code_files: counts[:untagged_code_files],
        untagged_test_files: counts[:untagged_test_files],
        report_excerpt: @output.lines.first(120).join.strip
      )
    end

    private

    def capture_count(pattern)
      @output[pattern, 1].to_i
    end

    def stale_arrow_count
      needs_work = count_lines_after("  Needs work:")
      stale = count_lines_after("  Stale (>30 days since audit):")
      needs_work + stale
    end

    def count_lines_after(header)
      lines = @output.lines
      start = lines.index { |line| line == "#{header}\n" || line == header }
      return 0 unless start

      count = 0
      lines[(start + 1)..].each do |line|
        break if line.start_with?("═") || line.strip.empty?
        break unless line.start_with?("    ")

        count += 1
      end
      count
    end

    def summary_line(counts)
      return "Coherence check passed with no structural findings." if counts.values.sum.zero?

      "Coherence soft-block: #{counts[:reverse_orphans]} reverse orphans, " \
        "#{counts[:uncovered_specs]} uncovered specs, " \
        "#{counts[:broken_arrow_refs]} arrow reference issues, " \
        "#{counts[:stale_arrows]} stale arrows, " \
        "#{counts[:untagged_code_files]} untagged code files, " \
        "#{counts[:untagged_test_files]} untagged test files."
    end
  end
end
