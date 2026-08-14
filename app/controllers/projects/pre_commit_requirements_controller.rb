# frozen_string_literal: true

module Projects
  class PreCommitRequirementsController < ApplicationController
    before_action :set_project
    before_action :set_pre_commit_requirement, only: [ :show, :update, :destroy ]

    def index
      authorize @project, :show?
      load_requirements

      respond_to do |format|
        format.html
        format.json { render json: @pre_commit_requirements }
      end
    end

    def show
      authorize @pre_commit_requirement

      respond_to do |format|
        format.json { render json: @pre_commit_requirement }
      end
    end

    def create
      authorize @project, :update?
      @pre_commit_requirement = @project.pre_commit_requirements.build(pre_commit_requirement_params)
      @pre_commit_requirement.account = @project.account

      if @pre_commit_requirement.save
        redirect_to project_pre_commit_requirements_path(@project),
          notice: "Pre-commit requirement created."
      else
        load_requirements
        assign_failed_requirement
        render :index, status: :unprocessable_content
      end
    end

    def update
      authorize @pre_commit_requirement

      if @pre_commit_requirement.update(pre_commit_requirement_params)
        redirect_to project_pre_commit_requirements_path(@project),
          notice: "Pre-commit requirement updated."
      else
        load_requirements
        assign_failed_requirement
        render :index, status: :unprocessable_content
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

    def load_requirements
      @pre_commit_requirements = @project.pre_commit_requirements.ordered
      @mutation_requirement = mutation_requirement_for_form
      @can_manage_pre_commit_requirements = policy(@project).update?
    end

    def assign_failed_requirement
      return if @pre_commit_requirement.check_type == "mutation_test"

      @new_requirement = @pre_commit_requirement
    end

    def mutation_requirement_for_form
      return @pre_commit_requirement if @pre_commit_requirement&.check_type == "mutation_test"

      @project.pre_commit_requirements.find_by(check_type: "mutation_test") ||
        @project.pre_commit_requirements.build(
          account: @project.account,
          name: "mutation_test",
          check_type: "mutation_test",
          command: PreCommitRequirement::MUTATION_TEST_DEFAULT_COMMAND,
          failure_behavior: "warn",
          position: 0,
          enabled: false
        )
    end

    def pre_commit_requirement_params
      params.require(:pre_commit_requirement).permit(
        :name, :command, :check_type, :fix_command,
        :failure_behavior, :position, :enabled
      )
    end
  end
end
