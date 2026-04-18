# frozen_string_literal: true

module Projects
  class PrTemplatesController < ApplicationController
    before_action :set_project
    before_action :set_pr_template, only: [ :show, :update, :destroy ]

    def index
      authorize @project, :show?
      @pr_templates = @project.pr_templates.ordered
      render json: @pr_templates
    end

    def show
      authorize @pr_template
      render json: @pr_template
    end

    def create
      authorize @project, :update?
      @pr_template = @project.pr_templates.build(pr_template_params)
      @pr_template.account = @project.account

      if @pr_template.save
        render json: @pr_template, status: :created
      else
        render json: { errors: @pr_template.errors }, status: :unprocessable_content
      end
    end

    def update
      authorize @pr_template

      if @pr_template.update(pr_template_params)
        render json: @pr_template
      else
        render json: { errors: @pr_template.errors }, status: :unprocessable_content
      end
    end

    def destroy
      authorize @pr_template
      @pr_template.destroy!
      head :no_content
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_pr_template
      @pr_template = @project.pr_templates.find(params[:id])
    end

    def pr_template_params
      params.require(:pr_template).permit(
        :name, :pr_type, :body, :description, :position, :enabled
      )
    end
  end
end
