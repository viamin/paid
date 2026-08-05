# frozen_string_literal: true

module Accounts
  class RoiDashboardStats
    WINDOW = 90.days
    TREND_MONTHS = 6

    def self.call(...)
      new(...).call
    end

    def self.overview(...)
      new(...).summary
    end

    def initialize(account:)
      @account = account
    end

    def call
      {
        summary: summary,
        trend: trend,
        benchmark_rollups: benchmark_rollups,
        project_rows: project_rows,
        executive_summary: Roi::ExecutiveSummary.call(
          scope_label: account.name,
          summary: summary,
          benchmarks: benchmark_rollups
        ),
        metric_definitions: Roi::MetricDefinitions::ALL,
        templates: Roi::ExperimentTemplates::ALL
      }
    end

    def summary
      @summary ||= Roi::MetricsCalculator.call(
        agent_runs: account_runs,
        related_runs: account_runs,
        window: current_window
      )
    end

    private

    attr_reader :account

    def project_rows
      @project_rows ||= begin
        runs_by_project = current_window_runs.group_by(&:project_id)

        account.projects.order(:name).map do |project|
          project_runs = runs_by_project.fetch(project.id, [])

          {
            project: project,
            summary: Roi::MetricsCalculator.call(
              agent_runs: project_runs,
              related_runs: project_runs,
              window: current_window
            )
          }
        end
      end
    end

    def benchmark_rollups
      @benchmark_rollups ||= account.roi_benchmarks.recent.group_by do |benchmark|
        [ benchmark.benchmark_type, benchmark.tool_name.presence || benchmark.name ]
      end.map do |(benchmark_type, label), rows|
        accepted_weight = rows.sum(&:accepted_pr_count)
        {
          benchmark_label: label,
          benchmark_type: benchmark_type,
          accepted_pr_count: accepted_weight,
          merge_rate: weighted_average(rows, :merge_rate),
          average_cycle_time_hours: weighted_average(rows, :average_cycle_time_hours),
          rework_rate: weighted_average(rows, :rework_rate),
          defect_escape_rate: weighted_average(rows, :defect_escape_rate),
          cost_per_accepted_pr_cents: weighted_average(rows, :cost_per_accepted_pr_cents)&.round
        }
      end.sort_by { |row| -row[:accepted_pr_count].to_i }
    end

    def trend
      TREND_MONTHS.times.map do |offset|
        start_time = (TREND_MONTHS - offset - 1).months.ago.beginning_of_month
        end_time = start_time.end_of_month
        snapshot = Roi::MetricsCalculator.call(
          agent_runs: account_runs,
          related_runs: account_runs,
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

    def weighted_average(rows, field)
      values = rows.filter_map do |row|
        value = row.public_send(field)
        next if value.nil?

        weight = row.accepted_pr_count
        next if weight.zero?

        [ value.to_f, weight ]
      end
      return nil if values.empty?

      divisor = values.sum { |(_, weight)| weight }
      return nil if divisor.zero?

      (values.sum { |(value, weight)| value * weight } / divisor.to_f).round(2)
    end

    def account_runs
      @account_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
    end

    def current_window
      WINDOW.ago..Time.current
    end

    def current_window_runs
      @current_window_runs ||= account_runs
        .reported_create_pr
        .where(status: "completed")
        .where.not(pull_request_number: nil)
        .where(created_at: current_window)
        .includes(:issue, :quality_metrics)
        .order(:created_at)
        .to_a
    end
  end
end
