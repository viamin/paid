# frozen_string_literal: true

module Projects
  class RoiDashboardStats
    WINDOW = 90.days
    TREND_MONTHS = 6

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      {
        summary: summary,
        trend: trend,
        benchmarks: benchmarks,
        executive_summary: Roi::ExecutiveSummary.call(
          scope_label: project.name,
          summary: summary,
          benchmarks: benchmarks
        ),
        metric_definitions: Roi::MetricDefinitions::ALL,
        templates: Roi::ExperimentTemplates::ALL
      }
    end

    private

    attr_reader :project

    def summary
      @summary ||= Roi::MetricsCalculator.call(
        agent_runs: project.agent_runs,
        related_runs: project.agent_runs,
        window: current_window
      )
    end

    def benchmarks
      @benchmarks ||= project.roi_benchmarks.recent.map do |benchmark|
        {
          id: benchmark.id,
          benchmark_label: benchmark.benchmark_label,
          benchmark_type: benchmark.benchmark_type,
          tool_name: benchmark.tool_name,
          starts_at: benchmark.starts_at,
          ends_at: benchmark.ends_at,
          accepted_pr_count: benchmark.accepted_pr_count,
          merge_rate: benchmark.merge_rate&.to_f,
          average_cycle_time_hours: benchmark.average_cycle_time_hours&.to_f,
          rework_rate: benchmark.rework_rate&.to_f,
          defect_escape_rate: benchmark.defect_escape_rate&.to_f,
          cost_per_accepted_pr_cents: benchmark.cost_per_accepted_pr_cents,
          notes: benchmark.notes
        }
      end
    end

    def trend
      TREND_MONTHS.times.map do |offset|
        start_time = (TREND_MONTHS - offset - 1).months.ago.beginning_of_month
        end_time = start_time.end_of_month
        snapshot = Roi::MetricsCalculator.call(
          agent_runs: project.agent_runs,
          related_runs: project.agent_runs,
          window: start_time..end_time
        )

        {
          label: start_time.strftime("%b %Y"),
          starts_at: start_time,
          ends_at: end_time,
          **snapshot
        }
      end
    end

    def current_window
      WINDOW.ago..Time.current
    end
  end
end
