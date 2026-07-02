# frozen_string_literal: true

class RunnerCredentialsController < ApplicationController
  DEFAULT_AUTH_KIND = "oauth_token"
  DEFAULT_RUNNER_KEY = "claude"

  before_action :set_runner_key_options, only: [ :new, :create ]
  before_action :set_runner_credential, only: [ :show, :destroy ]

  def index
    authorize RunnerCredential
    @runner_credentials = policy_scope(RunnerCredential).order(created_at: :desc, id: :desc)
  end

  def show
    authorize @runner_credential
  end

  def new
    @runner_credential = current_account.runner_credentials.build(default_credential_attributes)
    authorize @runner_credential
  end

  def create
    @runner_credential = current_account.runner_credentials.build(runner_credential_params)
    @runner_credential.created_by = current_user
    @runner_credential.auth_kind = DEFAULT_AUTH_KIND
    authorize @runner_credential

    if @runner_credential.save
      redirect_to runner_credential_path(@runner_credential), notice: "Credential saved."
    else
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    authorize @runner_credential
    @runner_credential.revoke!
    redirect_to runner_credentials_path, notice: "Credential was successfully deactivated."
  end

  private

  def set_runner_credential
    @runner_credential = policy_scope(RunnerCredential).find(params[:id])
  end

  def set_runner_key_options
    @runner_key_options = subscription_runner_key_options
  end

  def default_credential_attributes
    {
      runner_key: runner_key_options.include?(params[:runner_key]) ? params[:runner_key] : DEFAULT_RUNNER_KEY,
      auth_kind: DEFAULT_AUTH_KIND,
      long_lived: true
    }
  end

  def runner_credential_params
    params.require(:runner_credential).permit(:name, :runner_key, :token, :long_lived, :expires_at)
  end

  def runner_key_options
    @runner_key_options.presence || subscription_runner_key_options
  end

  def subscription_runner_key_options
    keys = RunnerSupport.subscription_auth_unset_vars.keys
    keys = [ DEFAULT_RUNNER_KEY ] unless keys.any?
    keys.sort
  end
end
