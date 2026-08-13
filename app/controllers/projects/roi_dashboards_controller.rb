# frozen_string_literal: true

require "csv"

module Projects
  class RoiDashboardsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :show?
      @stats = Projects::RoiDashboardStats.call(project: @project)
      @roi_benchmark = @project.roi_benchmarks.build
    end

    def export
      authorize @project, :show?
      stats = Projects::RoiDashboardStats.call(project: @project)

      send_data generate_csv(stats),
        filename: "roi-report-#{@project.name.parameterize}-#{Date.current}.csv",
        type: "text/csv"
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def generate_csv(stats)
      CSV.generate do |csv|
        csv << [ "Executive Summary" ]
        stats[:executive_summary].each { |line| csv << [ line ] }
        csv << []
        csv << [ "Metric", "Paid Current", "Benchmark" ]

        Roi::MetricDefinitions::ALL.each do |definition|
          csv << [ definition[:name], stats[:summary][definition[:key]], nil ]
        end

        csv << []
        csv << [ "Benchmarks" ]
        csv << [ "Label", "Type", "Accepted PRs", "Merge Rate", "Cycle Time (hrs)", "Rework Rate", "Defect Escape Rate", "Cost / Accepted PR (cents)" ]
        stats[:benchmarks].each do |benchmark|
          csv << [
            benchmark[:benchmark_label],
            benchmark[:benchmark_type],
            benchmark[:accepted_pr_count],
            benchmark[:merge_rate],
            benchmark[:average_cycle_time_hours],
            benchmark[:rework_rate],
            benchmark[:defect_escape_rate],
            benchmark[:cost_per_accepted_pr_cents]
          ]
        end

        csv << []
        csv << [ "Trend" ]
        csv << [ "Period", "Accepted PRs", "Merge Rate", "Cycle Time (hrs)", "Rework Rate", "Defect Escape Rate", "Cost / Accepted PR (cents)" ]
        stats[:trend].each do |row|
          csv << [
            row[:label],
            row[:accepted_pr_count],
            row[:merge_rate],
            row[:average_cycle_time_hours],
            row[:rework_rate],
            row[:defect_escape_rate],
            row[:cost_per_accepted_pr_cents]
          ]
        end
      end
    end
  end
end
