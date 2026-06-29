# frozen_string_literal: true

class RunnerCredentialsController < ApplicationController
  SETUP_TOKEN_AUTH_KIND = "oauth_token"

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
    if (credential = active_runner_credential)
      redirect_to_existing_credential(credential)
      return
    end

    @runner_credential = current_account.runner_credentials.build(default_credential_attributes)
    authorize @runner_credential
  end

  def create
    if (credential = active_runner_credential)
      redirect_to_existing_credential(credential)
      return
    end

    @runner_credential = current_account.runner_credentials.build(
      default_credential_attributes.merge(runner_credential_params)
    )
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
    policy_scope(RunnerCredential).where(runner_key: @runner.runner_key)
  end

  def default_credential_attributes
    {
      runner_key: @runner.runner_key
    }.tap do |attributes|
      attributes[:name] = generated_credential_name if RunnerCredential.supports_name_attribute?
      attributes[:auth_kind] = SETUP_TOKEN_AUTH_KIND if RunnerCredential.supports_auth_kind_attribute?
    end
  end

  def generated_credential_name
    "#{@runner.display_name} setup token #{Time.current.utc.iso8601(6)}"
  end

  def active_runner_credential
    @active_runner_credential ||= filtered_scope.active.order(created_at: :desc).first
  end

  def redirect_to_existing_credential(credential)
    authorize credential, :show?
    redirect_to existing_credential_redirect_path(credential), alert: existing_credential_redirect_message
  end

  def existing_credential_redirect_path(credential)
    runner_runner_credential_path(@runner, credential)
  end

  def existing_credential_redirect_message
    "This runner already has an active credential. Revoke it before adding a replacement."
  end

  def runner_credential_params
    params.require(:runner_credential).permit(:token, :long_lived)
  end
end
