# frozen_string_literal: true

class RunnerCredentialsController < ApplicationController
  before_action :set_runner
  before_action :set_runner_credential, only: [ :show, :destroy ]

  def index
    authorize RunnerCredential
    @runner_credentials = filtered_scope.order(created_at: :desc)
  end

  def show
    authorize @runner_credential
  end

  def new
    @runner_credential = current_account.runner_credentials.build(runner: @runner)
    authorize @runner_credential
  end

  def create
    @runner_credential = current_account.runner_credentials.build(runner_credential_params)
    @runner_credential.runner = @runner
    @runner_credential.created_by = current_user
    authorize @runner_credential

    if @runner_credential.save
      redirect_to runner_runner_credentials_path(@runner), notice: "Runner credential saved."
    else
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    authorize @runner_credential
    @runner_credential.revoke!
    redirect_to runner_runner_credentials_path(@runner), notice: "Credential was successfully revoked."
  end

  private

  def set_runner
    @runner = Runner.kept_only.joins(:user).where(users: { account_id: current_account.id }).find(params[:runner_id])
  end

  def set_runner_credential
    @runner_credential = filtered_scope.find(params[:id])
  end

  def filtered_scope
    policy_scope(RunnerCredential).where(runner: @runner)
  end

  def runner_credential_params
    params.require(:runner_credential).permit(:token, :long_lived)
  end
end
