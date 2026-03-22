# frozen_string_literal: true

class ProvidersController < ApplicationController
  before_action :set_provider, only: [ :edit, :update, :destroy, :test_agent ]
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
    validate_container_executable!

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
    @provider.assign_attributes(provider_params)
    validate_container_executable!

    if @provider.errors.none? && @provider.save
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

  # Rate-limited to one test per provider every 30 seconds to avoid
  # tying up Puma threads — the agent harness call is synchronous and
  # can block for up to TIMEOUT seconds.
  PROVIDER_TEST_COOLDOWN = 30.seconds

  def test_agent
    authorize @provider

    # Use an atomic cache write to avoid a race condition where two
    # concurrent requests both see a miss and proceed to run the test.
    cache_key = "provider_test_cooldown:#{@provider.id}"
    acquired = Rails.cache.write(
      cache_key,
      true,
      expires_in: PROVIDER_TEST_COOLDOWN,
      unless_exist: true
    )

    unless acquired
      render json: { success: false, error_type: "rate_limited",
                     message: "Please wait before testing this provider again." },
             status: :too_many_requests
      return
    end

    result = Providers::TestAgent.call(provider: @provider)

    render json: {
      success: result.success?,
      error_type: result.error_type,
      message: result.message
    }
  end

  def settings
    @user_setting = current_user.settings
    authorize @user_setting, :update?

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
    addable_keys = Provider.addable_provider_keys
    existing_keys = current_user.providers.pluck(:provider_key)
    @provider_options = if @provider&.persisted?
      (addable_keys - (existing_keys - [ @provider.provider_key ]))
    else
      addable_keys - existing_keys
    end
  end

  def validate_provider_key_enabled!
    return if @provider.provider_key.blank?
    return if Provider.addable_provider_key?(@provider.provider_key)

    message = if Provider.supported_provider_key?(@provider.provider_key)
      "is not available in paid-agent yet"
    else
      "is not supported"
    end

    @provider.errors.add(:provider_key, message)
  end

  def validate_container_executable!
    return if @provider.provider_key.blank?
    return if ProviderSupport.container_executable_provider_key?(@provider.provider_key)

    setting_agent_runs = @provider.enabled_for_agent_runs && (@provider.new_record? || @provider.will_save_change_to_attribute?("enabled_for_agent_runs", to: true))
    setting_fallback = @provider.enabled_for_fallback && (@provider.new_record? || @provider.will_save_change_to_attribute?("enabled_for_fallback", to: true))

    if setting_agent_runs
      @provider.errors.add(:enabled_for_agent_runs, "cannot be enabled for a provider whose CLI is not installed in the agent container")
    end
    if setting_fallback
      @provider.errors.add(:enabled_for_fallback, "cannot be enabled for a provider whose CLI is not installed in the agent container")
    end
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

    default_key = Provider.default_provider_key
    return [] unless default_key

    default = current_user.providers.find_or_initialize_by(provider_key: default_key)
    default.enabled_for_agent_runs = true
    default.enabled_for_fallback = true if default.new_record?

    return UserSetting.enabled_agent_providers(current_user) if default.save

    Rails.logger.error(
      message: "providers.ensure_run_enabled_provider_failed",
      user_id: current_user.id,
      errors: default.errors.full_messages
    )
    []
  end

  def load_index_context
    @providers = policy_scope(Provider).ordered
    @provider_states = current_user.provider_states.index_by(&:provider_name)
    @user_setting = current_user.settings
    @enabled_agent_providers = UserSetting.enabled_agent_providers(current_user)
    @fallback_candidate_providers = UserSetting.fallback_candidate_providers(current_user)
    @addable_provider_options = Provider.addable_provider_keys - current_user.providers.pluck(:provider_key)
  end

  def provider_settings_params
    permitted = params.require(:user_setting).permit(
      :default_agent_provider,
      :fallback_enabled,
      :fallback_providers
    )

    if permitted.key?(:fallback_providers)
      permitted[:fallback_providers] = UserSetting.normalize_fallback_providers_param(permitted[:fallback_providers])
    end

    permitted
  end
end
