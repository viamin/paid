# frozen_string_literal: true

module Projects
  class QualityThresholdsController < ApplicationController
    before_action :set_project

    def update
      authorize @project, :update?

      QualityThreshold.transaction do
        threshold_rows.each { |row| upsert_threshold(row) }
      end

      redirect_to project_quality_dashboard_path(@project), notice: "Quality thresholds were updated."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to project_quality_dashboard_path(@project), alert: e.record.errors.full_messages.to_sentence
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def threshold_rows
      params.fetch(:quality_thresholds, {}).values
    end

    def upsert_threshold(row)
      existing = QualityThreshold.override_for(
        project: @project,
        metric_type: row.fetch("metric_type"),
        goal_type: row.fetch("goal_type")
      )

      return existing&.destroy! unless truthy?(row["override"])

      threshold = existing || @project.quality_thresholds.build(
        account: @project.account,
        metric_type: row.fetch("metric_type"),
        goal_type: row.fetch("goal_type")
      )
      threshold.update!(
        min_value: row.fetch("min_value"),
        enabled: truthy?(row["enabled"])
      )
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
