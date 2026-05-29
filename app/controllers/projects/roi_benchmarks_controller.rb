# frozen_string_literal: true

module Projects
  class RoiBenchmarksController < ApplicationController
    before_action :set_project
    before_action :set_roi_benchmark, only: :destroy

    def create
      authorize @project, :update?

      @project.roi_benchmarks.create!(roi_benchmark_params)
      redirect_to project_roi_dashboard_path(@project), notice: "ROI benchmark added."
    rescue ActiveRecord::RecordInvalid => e
      @stats = Projects::RoiDashboardStats.call(project: @project)
      @roi_benchmark = e.record
      flash.now[:alert] = @roi_benchmark.errors.full_messages.to_sentence
      render "projects/roi_dashboards/show", status: :unprocessable_content
    end

    def destroy
      authorize @project, :update?

      @roi_benchmark.destroy!
      redirect_to project_roi_dashboard_path(@project), notice: "ROI benchmark removed."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_roi_benchmark
      @roi_benchmark = @project.roi_benchmarks.find(params[:id])
    end

    def roi_benchmark_params
      params.require(:roi_benchmark).permit(
        :name,
        :benchmark_type,
        :tool_name,
        :starts_at,
        :ends_at,
        :merge_rate,
        :average_cycle_time_hours,
        :rework_rate,
        :defect_escape_rate,
        :cost_per_accepted_pr_cents,
        :accepted_pr_count,
        :notes
      )
    end
  end
end
