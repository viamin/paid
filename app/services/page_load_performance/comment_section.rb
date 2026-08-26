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
      "| #{route_label(comparison.route_name)} | #{comparison.metric || "—"} | #{ms(comparison.baseline_ms)} | " \
        "#{ms(comparison.current_ms)} | #{delta(comparison)} | #{ms(comparison.trailing_median_ms)} | " \
        "#{status_label(comparison)} |"
    end

    # Route names come from the repository's screenshot config, so they are
    # escaped the way the surrounding screenshot comment escapes its own labels
    # — an unescaped pipe or backtick would break the table or inject markdown
    # into a comment Paid posts under its own identity.
    def route_label(route_name)
      "`#{route_name.to_s.gsub(/[\\`\[\]()<>|]/) { |char| "\\#{char}" }}`"
    end

    def status_label(comparison)
      label = LABELS.fetch(comparison.status, comparison.status)
      return label unless comparison.finding&.followup_exhausted?

      "#{label} · automated attempts exhausted"
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
