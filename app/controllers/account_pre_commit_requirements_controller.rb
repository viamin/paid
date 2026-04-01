# frozen_string_literal: true

class AccountPreCommitRequirementsController < ApplicationController
  skip_after_action :verify_authorized, only: :index
  before_action :set_pre_commit_requirement, only: [ :show, :update, :destroy ]

  def index
    @pre_commit_requirements = policy_scope(PreCommitRequirement)
      .for_account(current_account)
      .ordered
    render json: @pre_commit_requirements
  end

  def show
    authorize @pre_commit_requirement
    render json: @pre_commit_requirement
  end

  def create
    @pre_commit_requirement = current_account.pre_commit_requirements.build(
      pre_commit_requirement_params
    )
    authorize @pre_commit_requirement

    if @pre_commit_requirement.save
      redirect_to account_pre_commit_requirements_path,
        notice: "Pre-commit requirement created."
    else
      render json: { errors: @pre_commit_requirement.errors }, status: :unprocessable_content
    end
  end

  def update
    authorize @pre_commit_requirement

    if @pre_commit_requirement.update(pre_commit_requirement_params)
      redirect_to account_pre_commit_requirements_path,
        notice: "Pre-commit requirement updated."
    else
      render json: { errors: @pre_commit_requirement.errors }, status: :unprocessable_content
    end
  end

  def destroy
    authorize @pre_commit_requirement
    @pre_commit_requirement.destroy!
    redirect_to account_pre_commit_requirements_path,
      notice: "Pre-commit requirement removed."
  end

  private

  def set_pre_commit_requirement
    @pre_commit_requirement = policy_scope(PreCommitRequirement)
      .for_account(current_account)
      .find(params[:id])
  end

  def pre_commit_requirement_params
    params.require(:pre_commit_requirement).permit(
      :name, :command, :check_type, :fix_command,
      :failure_behavior, :position, :enabled
    )
  end
end
