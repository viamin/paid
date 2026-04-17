# frozen_string_literal: true

require "csv"

module Projects
  class QualityDashboardsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :show?
      @stats = QualityMetrics::DashboardStats.call(project: @project)
    end

    def export
      authorize @project, :show?
      stats = QualityMetrics::DashboardStats.new(project: @project)
      data = stats.export_data

      respond_to do |format|
        format.csv do
          send_data generate_csv(data),
            filename: "quality-report-#{@project.name.parameterize}-#{Date.current}.csv",
            type: "text/csv"
        end
      end
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def generate_csv(data)
      return "" if data.empty?

      headers = %w[id date metric_type composite_score feedback_source agent_run_id provider goal prompt_version]
      score_keys = data.flat_map { |d| d[:scores]&.keys || [] }.uniq.sort

      CSV.generate do |csv|
        csv << headers + score_keys
        data.each do |row|
          csv << headers.map { |h| row[h.to_sym] } + score_keys.map { |k| row[:scores]&.dig(k) }
        end
      end
    end
  end
end
