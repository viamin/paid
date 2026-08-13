# frozen_string_literal: true

require "csv"

module Accounts
  class RoiDashboardsController < ApplicationController
    def show
      authorize current_account
      @stats = Accounts::RoiDashboardStats.call(account: current_account)
    end

    def export
      authorize current_account, :show?
      stats = Accounts::RoiDashboardStats.call(account: current_account)

      send_data generate_csv(stats),
        filename: "account-roi-report-#{current_account.slug}-#{Date.current}.csv",
        type: "text/csv"
    end

    private

    def generate_csv(stats)
      CSV.generate do |csv|
        csv << [ "Executive Summary" ]
        stats[:executive_summary].each { |line| csv << [ line ] }
        csv << []
        csv << [ "Metric", "Account Current" ]
        Roi::MetricDefinitions::ALL.each do |definition|
          csv << [ definition[:name], stats[:summary][definition[:key]] ]
        end

        csv << []
        csv << [ "Benchmark Rollups" ]
        csv << [ "Label", "Type", "Accepted PRs", "Merge Rate", "Cycle Time (hrs)", "Rework Rate", "Defect Escape Rate", "Cost / Accepted PR (cents)" ]
        stats[:benchmark_rollups].each do |benchmark|
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
        csv << [ "Projects" ]
        csv << [ "Project", "Accepted PRs", "Merge Rate", "Cycle Time (hrs)", "Rework Rate", "Defect Escape Rate", "Cost / Accepted PR (cents)" ]
        stats[:project_rows].each do |row|
          csv << [
            row[:project].name,
            row[:summary][:accepted_pr_count],
            row[:summary][:merge_rate],
            row[:summary][:average_cycle_time_hours],
            row[:summary][:rework_rate],
            row[:summary][:defect_escape_rate],
            row[:summary][:cost_per_accepted_pr_cents]
          ]
        end
      end
    end
  end
end
