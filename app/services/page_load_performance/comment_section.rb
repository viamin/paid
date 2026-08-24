# frozen_string_literal: true

module PageLoadPerformance
  # Renders the page load table for the screenshot pull request comment, so
  # performance lands next to the visual before/after it belongs with.
  #
  # @spec PAGE-LOAD-REGRESSION-007
  class CommentSection
    LABELS = {
      "regressed" => "🔴 regressed",
      "unchanged" => "🟢 within threshold",
      "not_comparable" => "⚪ not comparable",
      "no_baseline" => "⚪ no baseline"
    }.freeze

    def self.call(...) = new(...).call

    def initialize(comparisons:)
      @comparisons = Array(comparisons)
    end

    def call
      return nil if comparisons.empty?

      [ "### Page load", "", table, "", footnote ].compact.join("\n")
    end

    private

    attr_reader :comparisons

    def table
      rows = comparisons.map { |comparison| row(comparison) }
      ([ "| Route | Metric | Before | After | Delta | Trailing median | |",
         "|---|---|---|---|---|---|---|" ] + rows).join("\n")
    end

    def row(comparison)
      "| `#{comparison.route_name}` | #{comparison.metric || "—"} | #{ms(comparison.baseline_ms)} | " \
        "#{ms(comparison.current_ms)} | #{delta(comparison)} | #{ms(comparison.trailing_median_ms)} | " \
        "#{LABELS.fetch(comparison.status, comparison.status)} |"
    end

    def delta(comparison)
      return "—" if comparison.delta_ms.nil?

      "#{comparison.delta_ms.positive? ? "+" : ""}#{comparison.delta_ms} ms"
    end

    def ms(value)
      value.nil? ? "—" : "#{value} ms"
    end

    def footnote
      return nil unless comparisons.any?(&:regressed?)

      "> Compared against the previous capture on this PR. A route is flagged only when it is slower " \
        "by both the configured ratio and absolute floor."
    end
  end
end
