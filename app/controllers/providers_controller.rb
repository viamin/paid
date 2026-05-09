# frozen_string_literal: true

class ProvidersController < ApplicationController
  # Lightweight stand-in for ProviderState used by the cached_provider_states
  # method.  Caching full ActiveRecord objects is brittle across deploys and
  # bloats the cache payload; this struct holds only the primitive attributes
  # the views actually read.
  CachedState = Struct.new(:circuit_state, :rate_limited_until, keyword_init: true) do
    def rate_limited?  = rate_limited_until.present? && rate_limited_until > Time.current
    def circuit_open?  = circuit_state == "open"
    def circuit_half_open? = circuit_state == "half_open"
  end
  before_action :set_provider, only: [ :edit, :update, :destroy, :test_agent ]
  before_action :load_provider_options, only: [ :new, :create, :edit, :update ]

  def index
    authorize Provider
    load_index_context
  end

  def new
    # CodeQL false positive: auth_type is not sensitive data — it's a UI routing
    # hint ("subscription" or "api_key") that selects which form variant to show.
    # The raw param is discarded immediately; only the allowlisted value is used.
    auth_type = sanitize_auth_type(params[:auth_type])

    # Only honor API key auth_type if the user has compatible API keys;
    # otherwise default to subscription to avoid a form with no radio selected.
    if auth_type == "api_key"
      load_provider_options unless instance_variable_defined?(:@api_key_provider_options)
      auth_type = "subscription" if @api_key_provider_options.blank?
    end

    @provider = current_user.providers.new(auth_type: auth_type)
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
      preserve_submitted_provider_key_in_options
      render :new, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotUnique
    @provider.errors.add(:provider_key, "already has an entry with this configuration")
    preserve_submitted_provider_key_in_options
    render :new, status: :unprocessable_content
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

    if @provider.discard
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

    update_fallback_provider_flags!
    weights_ok = update_provider_weights!

    attrs = provider_settings_params
    attrs[:default_agent_providers_by_goal] = goal_default_provider_attrs(attrs)

    if weights_ok && @user_setting.update(attrs)
      redirect_to providers_path, notice: "Provider settings saved successfully."
    else
      load_index_context
      render :index, status: :unprocessable_content
    end
  end

  private

  # Validates auth_type against the allowlist, defaulting to "subscription".
  # Extracted to make it clear to static analyzers (CodeQL) that the raw
  # query param is never used directly — only the sanitized value propagates.
  def sanitize_auth_type(raw)
    Provider::AUTH_TYPES.include?(raw) ? raw : "subscription"
  end

  def set_provider
    @provider = policy_scope(Provider).find(params[:id])
  end

  def provider_params
    permitted = [ :enabled_for_agent_runs, :enabled_for_fallback, :name, :fallback_role, :agent_co_author_trailer, :weight ]
    if action_name == "create"
      permitted.push(:provider_key, :auth_type, :provider_api_key_id)
    end
    attrs = params.require(:provider).permit(
      *permitted,
      config: { opencode: [ :api_provider, :model ], kilocode: [ :api_provider, :model ] },
      tier_model_ids: LlmModel::TIERS,
      complexity_thresholds: Provider::COMPLEXITY_THRESHOLD_KEYS
    )

    # Convert config to a plain Hash and slice to only the relevant provider_key,
    # avoiding stale config from previously visible form fields.
    # The final .to_h.merge returns a plain Hash (not ActionController::Parameters),
    # which prevents UnfilteredParameters when consumed by the model.
    config = attrs[:config]&.to_h || {}

    provider_key = attrs[:provider_key].presence || @provider&.provider_key
    config = config.slice(provider_key) if provider_key.present?

    result = attrs.to_h.merge("config" => config)
    if result.key?("tier_model_ids")
      result["tier_model_ids"] = result["tier_model_ids"].to_h.compact_blank
    end
    if result.key?("complexity_thresholds")
      result["complexity_thresholds"] = normalize_complexity_thresholds(result["complexity_thresholds"])
    end
    result
  end

  # Coerces blank-string form inputs to nil and integer-like strings to Ints,
  # dropping missing keys so they fall back to the model's default thresholds
  # rather than persisting blank values that fail the model-level validation.
  def normalize_complexity_thresholds(raw)
    return {} unless raw.is_a?(Hash)

    raw.each_with_object({}) do |(key, value), result|
      next unless Provider::COMPLEXITY_THRESHOLD_KEYS.include?(key.to_s)
      next if value.nil? || value.to_s.strip.empty?

      coerced = Integer(value, exception: false)
      result[key.to_s] = coerced || value
    end
  end

  def load_provider_options
    addable_keys = Provider.addable_provider_keys
    existing_subscription_keys = current_user.providers.kept_only.subscription.pluck(:provider_key)

    # Subscription providers: only show keys not yet added
    @subscription_provider_options = if @provider&.persisted?
      addable_keys - (existing_subscription_keys - [ @provider.provider_key ])
    else
      addable_keys - existing_subscription_keys
    end

    # API key providers: show all addable keys that have a compatible API key
    @available_api_keys = current_user.provider_api_keys.ordered
    @api_key_provider_options = addable_keys.select do |key|
      @available_api_keys.any? { |ak| compatible_api_key_for_provider?(api_key: ak, provider_key: key) }
    end

    # Combined for backward compat
    @provider_options = @subscription_provider_options
  end

  # When re-rendering :new after a validation failure, ensure the submitted
  # provider_key is present in the relevant options list so the <select>
  # preserves the user's selection and error messages make sense.
  def preserve_submitted_provider_key_in_options
    key = @provider.provider_key
    return if key.blank?

    if @provider.subscription?
      @subscription_provider_options |= [ key ] unless @subscription_provider_options.include?(key)
    elsif @provider.api_key?
      @api_key_provider_options |= [ key ] unless @api_key_provider_options.include?(key)
    end
  end

  def validate_provider_key_enabled!
    return if @provider.provider_key.blank?
    return if Provider.addable_provider_key?(@provider.provider_key)
    # Unsupported keys are caught by the model's inclusion validation;
    # here we only flag supported-but-not-yet-installed providers.
    return unless Provider.supported_provider_key?(@provider.provider_key)

    @provider.errors.add(:provider_key, "is not available in paid-agent yet")
  end

  def validate_container_executable!
    return if @provider.provider_key.blank?

    # On create, the model's inclusion validation catches unsupported keys.
    # On update, provider_key is immutable so that validation does not fire —
    # we must explicitly block enabling run/fallback flags for providers whose
    # key has been removed from the supported registry after creation.
    unless Provider.supported_provider_key?(@provider.provider_key)
      return if @provider.new_record?

      # Unlike the container-executable check below, unsupported providers
      # cannot function at all — block if either flag is true, regardless of
      # whether the user changed it in this request. The message tells the
      # user they need to disable the flag, not that they "cannot enable" it.
      if @provider.enabled_for_agent_runs
        @provider.errors.add(:enabled_for_agent_runs, "must be disabled for an unsupported provider")
      end
      if @provider.enabled_for_fallback
        @provider.errors.add(:enabled_for_fallback, "must be disabled for an unsupported provider")
      end
      return
    end

    return if Provider.addable_provider_key?(@provider.provider_key)

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

    run_identifiers = ensure_run_enabled_provider_identifiers!
    return false if run_identifiers.blank?

    fallback_identifiers = fallback_candidate_provider_identifiers

    attrs = {
      fallback_providers: settings.sanitize_provider_tokens(settings.fallback_providers, candidates: fallback_identifiers),
      default_agent_providers_by_goal: sanitize_goal_default_provider_identifiers(settings, run_identifiers)
    }

    default_identifier = settings.default_provider_identifier
    attrs[:default_agent_provider] = run_identifiers.first unless default_identifier && run_identifiers.include?(default_identifier)

    return true if settings.update(attrs)

    Rails.logger.error(
      message: "providers.reconcile_settings_failed",
      user_id: current_user.id,
      errors: settings.errors.full_messages
    )
    false
  end

  def ensure_run_enabled_provider_identifiers!
    run_identifiers = enabled_agent_provider_identifiers
    return run_identifiers if run_identifiers.present?

    default_key = Provider.default_provider_key
    return [] unless default_key

    default = current_user.providers.kept_only.find_or_initialize_by(provider_key: default_key, auth_type: "subscription")
    default.enabled_for_agent_runs = true
    default.enabled_for_fallback = true if default.new_record?

    return enabled_agent_provider_identifiers if default.save

    Rails.logger.error(
      message: "providers.ensure_run_enabled_provider_failed",
      user_id: current_user.id,
      errors: default.errors.full_messages
    )
    []
  end

  def load_index_context
    @providers = policy_scope(Provider).ordered
    @provider_states = cached_provider_states
    @user_setting = current_user.settings

    # Derive enabled/fallback identifiers from the already-loaded @providers
    # collection to avoid 2 extra queries.
    executable_keys = ProviderSupport.container_executable_provider_keys.to_set
    enabled_providers = @providers.select { |p| p.enabled_for_agent_runs? && executable_keys.include?(p.provider_key) }
    fallback_providers = @providers.select { |p| p.enabled_for_fallback? && executable_keys.include?(p.provider_key) }

    @enabled_agent_providers = UserSetting.provider_identifiers_for(enabled_providers, identifiers: true)
    @run_enabled_providers = run_enabled_providers_in_identifier_order(@enabled_agent_providers)
    @fallback_candidate_providers = UserSetting.provider_identifiers_for(fallback_providers, identifiers: true)
    @default_provider_identifier = @user_setting.default_provider_identifier
    @goal_provider_labels = {
      "create_pr" => "PR Agent",
      "review" => "Code Review Agent",
      "create_issue" => "Issue Agent"
    }
    @explicit_goal_default_providers = @user_setting.default_agent_providers_by_goal.slice(*AgentRun::GOALS)
    @saved_fallback_provider_tokens = @user_setting.sanitize_provider_tokens(
      @user_setting.fallback_providers,
      candidates: (@enabled_agent_providers + @fallback_candidate_providers).uniq
    )
    @provider_labels = @providers.each_with_object({}) do |provider, labels|
      labels[provider.routing_key] = provider.display_name
      labels[provider.provider_key] ||= provider.display_name
    end
    @subscription_provider_identifiers = @providers.select(&:subscription?).map(&:routing_key).to_set
    @provider_state_aliases = @providers.each_with_object({}) do |provider, aliases|
      aliases[provider.routing_key] = provider.provider_key
    end
    @usage_stats = Providers::UsageStats.call(user: current_user)
    # Pre-index stats per provider to avoid duplicate lookups in views
    @provider_stats_by_id = @providers.each_with_object({}) do |provider, hash|
      stats = @usage_stats[provider.routing_key] || @usage_stats[provider.provider_key]
      hash[provider.id] = stats
    end
    @available_api_keys = current_user.provider_api_keys.ordered
    existing_subscription_keys = @providers.select(&:subscription?).map(&:provider_key)
    addable_keys = Provider.addable_provider_keys
    api_key_compatible_addable_keys =
      addable_keys.select do |key|
        @available_api_keys.any? { |api_key| compatible_api_key_for_provider?(api_key: api_key, provider_key: key) }
      end
    @addable_provider_options = (
      (addable_keys - existing_subscription_keys) + api_key_compatible_addable_keys
    ).uniq.presence || []
  end

  def update_fallback_provider_flags!
    raw = params.dig(:user_setting, :enabled_fallback_provider_keys)
    return unless raw

    enabled_keys = UserSetting.normalize_fallback_providers_param(raw)
    # Treat empty result as "no change" to avoid disabling all providers on parse errors
    return if enabled_keys.blank?

    Provider.update_fallback_flags(current_user, enabled_keys)
  end

  def provider_settings_params
    permitted = params.require(:user_setting).permit(
      :default_agent_provider,
      :fallback_enabled,
      :fallback_providers,
      :provider_selection_mode,
      default_agent_providers_by_goal: AgentRun::GOALS
    )

    if permitted.key?(:fallback_providers)
      permitted[:fallback_providers] = UserSetting.normalize_fallback_providers_param(permitted[:fallback_providers])
    end

    if permitted.key?(:provider_selection_mode) && permitted[:provider_selection_mode].present?
      mode = permitted[:provider_selection_mode].to_s
      if UserSetting::PROVIDER_SELECTION_MODES.include?(mode)
        permitted[:provider_selection_mode] = mode
      else
        permitted.delete(:provider_selection_mode)
      end
    end

    expand_combined_provider_mode!(permitted)

    permitted
  end

  # Parses the combined provider_mode param into provider_selection_mode
  # and default_agent_provider. Values are either "single:<identifier>"
  # for a specific provider, or "round_robin"/"random" for multi-provider
  # distribution.
  def expand_combined_provider_mode!(permitted)
    combined = params.dig(:user_setting, :provider_mode).to_s.strip
    return if combined.blank?

    if combined.start_with?("single:")
      provider_identifier = combined.delete_prefix("single:")
      permitted[:provider_selection_mode] = "single"
      permitted[:default_agent_provider] = provider_identifier
    elsif UserSetting::PROVIDER_SELECTION_MODES.include?(combined)
      permitted[:provider_selection_mode] = combined
    end
  end

  # Applies per-provider weight updates from form params. Each entry must
  # be a positive integer; invalid values flash a single error and abort
  # the settings save so the user sees the failure rather than a silent
  # partial update.
  def update_provider_weights!
    raw = params.dig(:user_setting, :provider_weights)
    return true if raw.blank?

    weights = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    invalid = false
    Provider.transaction do
      weights.each do |provider_id, weight_value|
        provider = current_user.providers.kept_only.find_by(id: provider_id)
        next unless provider

        coerced = Integer(weight_value, exception: false)
        if coerced.nil? || coerced < 1 || coerced > Provider::MAX_WEIGHT
          @user_setting.errors.add(:base, "#{provider.display_name} weight must be an integer between 1 and #{Provider::MAX_WEIGHT}")
          invalid = true
          raise ActiveRecord::Rollback
        end

        next if provider.weight == coerced

        unless provider.update(weight: coerced)
          @user_setting.errors.add(:base, "#{provider.display_name} weight: #{provider.errors.full_messages.to_sentence}")
          invalid = true
          raise ActiveRecord::Rollback
        end
      end
    end

    !invalid
  end

  def cached_provider_states
    Rails.cache.fetch("providers/states/#{current_user.id}", expires_in: 30.seconds) do
      current_user.provider_states.each_with_object({}) do |state, hash|
        hash[state.provider_name] = CachedState.new(
          circuit_state: state.circuit_state,
          rate_limited_until: state.rate_limited_until
        )
      end
    end
  end

  def compatible_api_key_for_provider?(api_key:, provider_key:)
    # OpenCode and KiloCode support multiple API key types depending on the
    # selected api_provider, so check against all compatible service types.
    if %w[opencode kilocode].include?(provider_key)
      return Provider::DIRECT_OUTBOUND_SERVICE_TYPES.include?(api_key.api_service_type)
    end

    api_key.api_service_type == Provider.api_service_type_for(provider_key)
  end

  def enabled_agent_provider_identifiers
    executable_keys = ProviderSupport.container_executable_provider_keys
    providers = current_user.providers.kept_only.for_agent_runs
      .where(provider_key: executable_keys)
      .ordered
    UserSetting.provider_identifiers_for(providers, identifiers: true)
  end

  # Returns Provider records corresponding to the given routing-key
  # identifiers, preserving the identifier order so the settings UI can
  # render weight rows in the same order as the rest of the page.
  def run_enabled_providers_in_identifier_order(identifiers)
    return [] if identifiers.blank?

    ids = identifiers.filter_map { |identifier| Provider.id_from_routing_key(identifier) }
    providers_by_id = current_user.providers.kept_only.where(id: ids).index_by(&:id)
    ids.filter_map { |id| providers_by_id[id] }
  end

  def fallback_candidate_provider_identifiers
    executable_keys = ProviderSupport.container_executable_provider_keys
    providers = current_user.providers.kept_only.for_fallback
      .where(provider_key: executable_keys)
      .ordered
    UserSetting.provider_identifiers_for(providers, identifiers: true)
  end

  def sanitize_goal_default_provider_identifiers(settings, candidates)
    AgentRun::GOALS.each_with_object({}) do |goal, normalized|
      token = settings.default_agent_providers_by_goal[goal]
      next if token.blank?

      resolved = settings.sanitize_provider_tokens([ token ], candidates: candidates)
      next if resolved.blank?

      normalized[goal] = resolved.first
    end
  end

  def goal_default_provider_attrs(attrs)
    submitted = attrs[:default_agent_providers_by_goal]
    return sanitize_goal_default_provider_identifiers(@user_setting, enabled_agent_provider_identifiers) unless submitted

    raw_submitted = params.dig(:user_setting, :default_agent_providers_by_goal)
    return sanitize_goal_default_provider_identifiers(@user_setting, enabled_agent_provider_identifiers) if submitted.empty? && raw_goal_defaults_filtered_out?(raw_submitted)

    submitted
  end

  def raw_goal_defaults_filtered_out?(raw_submitted)
    return true unless raw_submitted.respond_to?(:keys)

    raw_submitted.keys.map(&:to_s).intersection(AgentRun::GOALS).empty?
  end
end
