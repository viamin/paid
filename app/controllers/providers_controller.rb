# frozen_string_literal: true

class ProvidersController < ApplicationController
  before_action :set_provider, only: [ :edit, :update, :destroy ]
  before_action :load_provider_options, only: [ :new, :create, :edit, :update ]

  def index
    authorize Provider
    @providers = policy_scope(Provider).ordered
  end

  def new
    @provider = current_user.providers.new
    authorize @provider
  end

  def create
    @provider = current_user.providers.new(provider_params)
    authorize @provider

    if @provider.save
      if reconcile_settings!
        redirect_to providers_path, notice: "Provider created successfully."
      else
        redirect_to providers_path, alert: "Provider created, but settings reconciliation failed. Please review settings."
      end
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
    authorize @provider
  end

  def update
    authorize @provider

    if @provider.update(provider_params)
      if reconcile_settings!
        redirect_to providers_path, notice: "Provider updated successfully."
      else
        redirect_to providers_path, alert: "Provider updated, but settings reconciliation failed. Please review settings."
      end
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @provider

    if @provider.destroy
      if reconcile_settings!
        redirect_to providers_path, notice: "Provider deleted successfully."
      else
        redirect_to providers_path, alert: "Provider deleted, but settings reconciliation failed. Please review settings."
      end
    else
      redirect_to providers_path, alert: @provider.errors.full_messages.to_sentence
    end
  end

  private

  def set_provider
    @provider = policy_scope(Provider).find(params[:id])
  end

  def provider_params
    permitted = [ :enabled_for_agent_runs, :enabled_for_fallback ]
    permitted << :provider_key if action_name == "create"
    params.require(:provider).permit(*permitted)
  end

  def load_provider_options
    @provider_options = UserSetting.system_enabled_provider_keys
  end

  def reconcile_settings!
    settings = current_user.settings

    run_keys = UserSetting.enabled_agent_providers(current_user)
    fallback_keys = UserSetting.fallback_candidate_providers(current_user)

    attrs = {
      fallback_providers: Array(settings.fallback_providers) & fallback_keys
    }

    attrs[:default_agent_provider] = run_keys.first unless run_keys.include?(settings.default_agent_provider)

    return true if settings.update(attrs)

    Rails.logger.error(
      message: "providers.reconcile_settings_failed",
      user_id: current_user.id,
      errors: settings.errors.full_messages
    )
    false
  end
end
