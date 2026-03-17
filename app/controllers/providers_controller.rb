# frozen_string_literal: true

class ProvidersController < ApplicationController
  before_action :set_provider, only: [ :edit, :update, :destroy ]
  before_action :load_provider_options, only: [ :new, :create, :edit, :update ]

  def index
    authorize Provider
    load_index_context
  end

  def new
    @provider = current_user.providers.new
    authorize @provider
  end

  def create
    @provider = current_user.providers.new(provider_params)
    authorize @provider
    validate_provider_key_enabled!

    if @provider.errors.none? && @provider.save
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

  def settings
    authorize current_user.providers.first_or_initialize(provider_key: "claude"), :update?
    @user_setting = current_user.settings

    if @user_setting.update(provider_settings_params)
      redirect_to providers_path, notice: "Provider settings saved successfully."
    else
      load_index_context
      render :index, status: :unprocessable_content
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
    system_enabled = UserSetting.system_enabled_provider_keys
    existing_keys = current_user.providers.pluck(:provider_key)
    @provider_options = if @provider&.persisted?
      (system_enabled - (existing_keys - [ @provider.provider_key ]))
    else
      system_enabled - existing_keys
    end
  end

  def validate_provider_key_enabled!
    return if @provider.provider_key.blank?
    return if UserSetting.system_enabled_provider_keys.include?(@provider.provider_key)

    @provider.errors.add(:provider_key, "is not currently available")
  end

  def reconcile_settings!
    settings = current_user.settings

    run_keys = ensure_run_enabled_provider_keys!
    return false if run_keys.blank?

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

  def ensure_run_enabled_provider_keys!
    run_keys = UserSetting.enabled_agent_providers(current_user)
    return run_keys if run_keys.present?

    claude = current_user.providers.find_or_initialize_by(provider_key: "claude")
    claude.enabled_for_agent_runs = true
    claude.enabled_for_fallback = true if claude.new_record?

    return UserSetting.enabled_agent_providers(current_user) if claude.save

    Rails.logger.error(
      message: "providers.ensure_run_enabled_provider_failed",
      user_id: current_user.id,
      errors: claude.errors.full_messages
    )
    []
  end

  def load_index_context
    @providers = policy_scope(Provider).ordered
    @provider_states = current_user.provider_states.index_by(&:provider_name)
    @user_setting = current_user.settings
    @enabled_agent_providers = UserSetting.enabled_agent_providers(current_user)
    @fallback_candidate_providers = UserSetting.fallback_candidate_providers(current_user)
  end

  def provider_settings_params
    permitted = params.require(:user_setting).permit(
      :default_agent_provider,
      :fallback_enabled,
      :fallback_providers
    )

    if permitted[:fallback_providers].is_a?(String)
      parsed = JSON.parse(permitted[:fallback_providers])
      permitted[:fallback_providers] = if parsed.is_a?(Array)
        parsed.select { |provider| provider.is_a?(String) }
      else
        []
      end
    end

    permitted
  rescue JSON::ParserError
    permitted[:fallback_providers] = []
    permitted
  end
end
