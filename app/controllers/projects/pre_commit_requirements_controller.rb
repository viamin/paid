# frozen_string_literal: true

module Projects
  class PreCommitRequirementsController < ApplicationController
    before_action :set_project
    before_action :set_pre_commit_requirement, only: [ :show, :update, :destroy ]

    def index
      authorize @project, :show?
      @pre_commit_requirements = @project.pre_commit_requirements.ordered
      render json: @pre_commit_requirements
    end

    def show
      authorize @pre_commit_requirement
      render json: @pre_commit_requirement
    end

    def create
      authorize @project, :update?
      @pre_commit_requirement = @project.pre_commit_requirements.build(pre_commit_requirement_params)
      @pre_commit_requirement.account = @project.account

      if @pre_commit_requirement.save
        redirect_to project_pre_commit_requirements_path(@project),
          notice: "Pre-commit requirement created."
      else
        render json: { errors: @pre_commit_requirement.errors }, status: :unprocessable_content
      end
    end

    def update
      authorize @pre_commit_requirement

      if @pre_commit_requirement.update(pre_commit_requirement_params)
        redirect_to project_pre_commit_requirements_path(@project),
          notice: "Pre-commit requirement updated."
      else
        render json: { errors: @pre_commit_requirement.errors }, status: :unprocessable_content
      end
    end

    def destroy
      authorize @pre_commit_requirement
      @pre_commit_requirement.destroy!
      redirect_to project_pre_commit_requirements_path(@project),
        notice: "Pre-commit requirement removed."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_pre_commit_requirement
      @pre_commit_requirement = @project.pre_commit_requirements.find(params[:id])
    end

    def pre_commit_requirement_params
      params.require(:pre_commit_requirement).permit(
        :name, :command, :check_type, :fix_command,
        :failure_behavior, :position, :enabled
      )
    end
  end
end
