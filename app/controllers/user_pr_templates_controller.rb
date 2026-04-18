# frozen_string_literal: true

class UserPrTemplatesController < ApplicationController
  skip_after_action :verify_authorized, only: :index
  before_action :set_pr_template, only: [ :show, :update, :destroy ]

  def index
    @pr_templates = policy_scope(PrTemplate)
      .for_user(current_user)
      .ordered
    render json: @pr_templates
  end

  def show
    authorize @pr_template
    render json: @pr_template
  end

  def create
    @pr_template = current_user.pr_templates.build(pr_template_params)
    authorize @pr_template

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

  def set_pr_template
    @pr_template = policy_scope(PrTemplate)
      .for_user(current_user)
      .find(params[:id])
  end

  def pr_template_params
    params.require(:pr_template).permit(
      :name, :pr_type, :body, :description, :position, :enabled
    )
  end
end
