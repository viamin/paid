# frozen_string_literal: true

class ProvidersController < ApplicationController
  before_action :set_provider, only: [ :edit, :update, :destroy ]

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
      reconcile_settings!
      redirect_to providers_path, notice: "Provider created successfully."
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
      reconcile_settings!
      redirect_to providers_path, notice: "Provider updated successfully."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @provider

    if @provider.destroy
      reconcile_settings!
      redirect_to providers_path, notice: "Provider deleted successfully."
    else
      redirect_to providers_path, alert: @provider.errors.full_messages.to_sentence
    end
  end

  private

  def set_provider
    @provider = policy_scope(Provider).find(params[:id])
  end

  def provider_params
    params.require(:provider).permit(:provider_key, :enabled_for_agent_runs, :enabled_for_fallback)
  end

  def reconcile_settings!
    settings = current_user.settings

    run_keys = UserSetting.enabled_agent_providers(current_user)
    fallback_keys = UserSetting.fallback_candidate_providers(current_user)

    attrs = {
      fallback_providers: Array(settings.fallback_providers) & fallback_keys
    }

    attrs[:default_agent_provider] = run_keys.first unless run_keys.include?(settings.default_agent_provider)

    settings.update!(attrs)
  end
end
