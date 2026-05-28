# frozen_string_literal: true

module Roi
  class ExecutiveSummary
    WINDOW_LABEL = "last 90 days".freeze
    INVERSE_METRICS = %i[average_cycle_time_hours rework_rate defect_escape_rate cost_per_accepted_pr_cents].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(scope_label:, summary:, benchmarks:)
      @scope_label = scope_label
      @summary = summary
      @benchmarks = benchmarks
    end

    def call
      [ production_line, comparison_line ].compact
    end

    private

    attr_reader :scope_label, :summary, :benchmarks

    def production_line
      if summary[:accepted_pr_count].zero?
        "#{scope_label} has no accepted PR evidence in the #{WINDOW_LABEL} yet. Start with a pilot template and add a baseline benchmark to quantify progress."
      else
        "#{scope_label} produced #{summary[:accepted_pr_count]} accepted PRs from #{summary[:created_pr_count]} created PRs in the #{WINDOW_LABEL}, with a #{summary[:merge_rate]}% merge rate, #{summary[:average_cycle_time_hours]}h average cycle time, and #{currency(summary[:cost_per_accepted_pr_cents])} cost per accepted PR."
      end
    end

    def comparison_line
      benchmark = benchmarks.max_by { |row| row[:accepted_pr_count].to_i }
      return "Add a human-only or commercial benchmark to produce a procurement-ready side-by-side comparison." if benchmark.nil?
      return unless summary[:accepted_pr_count].positive?

      comparisons = Roi::MetricDefinitions::ALL.filter_map do |definition|
        current = summary[definition[:key]]
        baseline = benchmark[definition[:key]]
        next if current.nil? || baseline.nil?

        delta = current - baseline
        favorable = INVERSE_METRICS.include?(definition[:key]) ? delta.negative? : delta.positive?
        next unless favorable

        {
          name: definition[:name],
          delta: delta,
          inverse: INVERSE_METRICS.include?(definition[:key])
        }
      end
      strongest = comparisons.max_by { |comparison| comparison[:delta].abs }
      return "Paid is being measured against #{benchmark[:benchmark_label]} across the full ROI framework." if strongest.nil?

      "#{scope_label} currently outperforms #{benchmark[:benchmark_label]} most clearly on #{strongest[:name].downcase} (#{delta_label(strongest[:delta], inverse: strongest[:inverse])})."
    end

    def delta_label(delta, inverse:)
      if inverse
        if delta.negative?
          magnitude = -delta
          magnitude.is_a?(Float) ? "#{magnitude.round(1)} lower" : "#{magnitude} lower"
        else
          "#{delta.round(1)} higher"
        end
      else
        "#{delta.round(1)} points"
      end
    end

    def currency(cents)
      return "--" if cents.nil?

      format("$%.2f", cents / 100.0)
    end
  end
end
