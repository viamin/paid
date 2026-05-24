# frozen_string_literal: true

class RunnersController < ApplicationController
  # Lightweight stand-in for RunnerState used by the cached_runner_states
  # method.  Caching full ActiveRecord objects is brittle across deploys and
  # bloats the cache payload; this struct holds only the primitive attributes
  # the views actually read.
  CachedState = Struct.new(:circuit_state, :rate_limited_until, keyword_init: true) do
    def rate_limited?  = rate_limited_until.present? && rate_limited_until > Time.current
    def circuit_open?  = circuit_state == "open"
    def circuit_half_open? = circuit_state == "half_open"
  end
  before_action :set_runner, only: [ :edit, :update, :destroy, :test_agent, :toggle_agent_runs, :toggle_fallback ]
  before_action :load_runner_options, only: [ :new, :create, :edit, :update ]

  def index
    authorize resource_model_class
    load_index_context
  end

  def new
    auth_type = sanitize_auth_type(params[:form_variant])

    # Only honor API key auth_type if the user has compatible API keys;
    # otherwise default to subscription to avoid a form with no radio selected.
    if auth_type == "api_key"
      load_runner_options unless instance_variable_defined?(:@api_key_runner_options)
      auth_type = "subscription" if @api_key_runner_options.blank?
    end

    @runner = resource_records.new(auth_type: auth_type)
    assign_legacy_provider_ivars(@runner)
    authorize @runner
  end

  def create
    @runner = resource_records.new(runner_params)
    assign_legacy_provider_ivars(@runner)
    authorize @runner
    validate_runner_key_enabled!
    validate_container_executable!

    if @runner.errors.none? && @runner.save
      if reconcile_settings!
        redirect_to resource_index_path, notice: resource_created_notice
      else
        redirect_to resource_index_path, alert: resource_reconciliation_alert(action: "created")
      end
    else
      preserve_submitted_runner_key_in_options
      render :new, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotUnique
    @runner.errors.add(:runner_key, "already has an entry with this configuration")
    preserve_submitted_runner_key_in_options
    render :new, status: :unprocessable_content
  end

  def edit
    authorize @runner
  end

  def update
    authorize @runner
    @runner.assign_attributes(runner_params)
    validate_container_executable!

    if @runner.errors.none? && @runner.save
      if reconcile_settings!
        redirect_to resource_index_path, notice: resource_updated_notice
      else
        redirect_to resource_index_path, alert: resource_reconciliation_alert(action: "updated")
      end
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @runner

    if @runner.discard
      if reconcile_settings!
        redirect_to resource_index_path, notice: resource_deleted_notice
      else
        redirect_to resource_index_path, alert: resource_reconciliation_alert(action: "deleted")
      end
    else
      redirect_to resource_index_path, alert: translated_resource_errors(@runner.errors.full_messages.to_sentence)
    end
  end

  # Rate-limited to one test per runner every 30 seconds to avoid
  # tying up Puma threads — the agent harness call is synchronous and
  # can block for up to TIMEOUT seconds.
  RUNNER_TEST_COOLDOWN = 30.seconds

  def test_agent
    authorize @runner

    # Use an atomic cache write to avoid a race condition where two
    # concurrent requests both see a miss and proceed to run the test.
    cache_key = "runner_test_cooldown:#{@runner.id}"
    acquired = Rails.cache.write(
      cache_key,
      true,
      expires_in: RUNNER_TEST_COOLDOWN,
      unless_exist: true
    )

    unless acquired
      render json: { success: false, error_type: "rate_limited",
                     message: "Please wait before testing this #{resource_noun} again." },
             status: :too_many_requests
      return
    end

    result = resource_test_agent_service.call(resource_test_agent_arguments)

    render json: {
      success: result.success?,
      error_type: result.error_type,
      message: result.message
    }
  end

  def toggle_agent_runs
    authorize @runner, :update?
    toggle_runner_flag(:enabled_for_agent_runs, "#{toggle_partial_prefix}/agent_runs_toggle_index")
  end

  def toggle_fallback
    authorize @runner, :update?
    toggle_runner_flag(:enabled_for_fallback, "#{toggle_partial_prefix}/fallback_toggle_index")
  end

  def settings
    @user_setting = current_user.settings
    authorize @user_setting, :update?

    update_fallback_runner_flags!
    weights_ok = update_runner_weights!

    attrs = runner_settings_params
    attrs[:default_agent_runners_by_goal] = goal_default_runner_attrs(attrs)

    if weights_ok && @user_setting.update(attrs)
      redirect_to resource_index_path, notice: resource_settings_saved_notice
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
    resource_model_class::AUTH_TYPES.include?(raw) ? raw : "subscription"
  end

  def set_runner
    @runner = policy_scope(resource_model_class).find(params[:id])
    assign_legacy_provider_ivars(@runner)
  end

  def runner_params
    raw_params = params[resource_param_key] || params.fetch(:runner)
    permitted = [ :enabled_for_agent_runs, :enabled_for_chat, :enabled_for_fallback, :name, :fallback_role, :agent_co_author_trailer, :weight ]
    if action_name == "create"
      permitted.push(:runner_key, :provider_key, :auth_type, :provider_api_key_id)
    end
    attrs = raw_params.permit(
      *permitted,
      config: { opencode: [ :api_provider, :model ], kilocode: [ :api_provider, :model, :preflight_timeout_seconds ], aider: [ :api_provider, :model ],
                pi: [ :api_provider, :model ] },
      tier_model_ids: LlmModel::TIERS,
      complexity_thresholds: Runner::COMPLEXITY_THRESHOLD_KEYS
    )

    # Convert config to a plain Hash and slice to only the relevant runner_key,
    # avoiding stale config from previously visible form fields.
    # The final .to_h.merge returns a plain Hash (not ActionController::Parameters),
    # which prevents UnfilteredParameters when consumed by the model.
    config = attrs[:config]&.to_h || {}

    runner_key = attrs[:runner_key].presence || attrs[:provider_key].presence || @runner&.runner_key
    config = config.slice(runner_key) if runner_key.present?

    result = attrs.to_h.merge("config" => config)
    result["runner_key"] = result.delete("provider_key") if result.key?("provider_key")
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
      next unless Runner::COMPLEXITY_THRESHOLD_KEYS.include?(key.to_s)
      next if value.nil? || value.to_s.strip.empty?

      coerced = Integer(value, exception: false)
      result[key.to_s] = coerced || value
    end
  end

  def load_runner_options
    addable_keys = resource_addable_keys
    existing_subscription_keys = resource_records.kept_only.subscription.pluck(:runner_key)

    # Subscription runners: only show keys not yet added
    @subscription_runner_options = if @runner&.persisted?
      addable_keys - (existing_subscription_keys - [ @runner.runner_key ])
    else
      addable_keys - existing_subscription_keys
    end

    # API key runners: show all addable keys that have a compatible API key
    @available_api_keys = current_user.provider_api_keys.ordered
    @api_key_runner_options = addable_keys.select do |key|
      @available_api_keys.any? { |ak| compatible_api_key_for_runner?(api_key: ak, runner_key: key) }
    end

    # Combined for backward compat
    @runner_options = @subscription_runner_options
    assign_legacy_provider_option_ivars
  end

  # When re-rendering :new after a validation failure, ensure the submitted
  # runner_key is present in the relevant options list so the <select>
  # preserves the user's selection and error messages make sense.
  def preserve_submitted_runner_key_in_options
    key = @runner.runner_key
    return if key.blank?

    if @runner.subscription?
      @subscription_runner_options |= [ key ] unless @subscription_runner_options.include?(key)
    elsif @runner.api_key?
      @api_key_runner_options |= [ key ] unless @api_key_runner_options.include?(key)
    end

    assign_legacy_provider_option_ivars
  end

  def validate_runner_key_enabled!
    return if @runner.runner_key.blank?
    return if resource_addable_key?(@runner.runner_key)
    # Unsupported keys are caught by the model's inclusion validation;
    # here we only flag supported-but-not-yet-installed runners.
    return unless resource_supported_key?(@runner.runner_key)

    @runner.errors.add(:runner_key, "is not available in paid-agent yet")
  end

  def toggle_runner_flag(attribute, partial)
    new_value = !@runner.public_send(:"#{attribute}?")
    @runner.assign_attributes(attribute => new_value)

    validate_container_executable_for_toggle(attribute)

    respond_to do |format|
      format.turbo_stream do
        success = if @runner.errors.none?
          resource_model_class.transaction do
            if @runner.save && reconcile_settings!
              true
            else
              raise ActiveRecord::Rollback
            end
          end
        end

        if success
          @runner.reload
          render turbo_stream: turbo_stream.replace(
            ActionView::RecordIdentifier.dom_id(@runner, :"#{attribute}_toggle"),
            partial: partial,
            locals: { toggle_partial_locals_key => @runner }
          )
        else
          @runner.reload if @runner.persisted?
          error_message = @runner.errors.full_messages.to_sentence.presence || "Could not update #{resource_noun}"
          render turbo_stream: [
            turbo_stream.replace(
              ActionView::RecordIdentifier.dom_id(@runner, :"#{attribute}_toggle"),
              partial: partial,
              locals: { toggle_partial_locals_key => @runner }
            ),
            turbo_stream.prepend("flash", partial: "shared/flash_alert", locals: { message: error_message })
          ], status: :unprocessable_content
        end
      end
      format.html { redirect_to resource_index_path }
    end
  end

  def validate_container_executable_for_toggle(attribute)
    return unless @runner.public_send(:"#{attribute}?")
    return unless @runner.will_save_change_to_attribute?(attribute.to_s, to: true)

    unless resource_supported_key?(@runner.runner_key)
      @runner.errors.add(attribute, "must be disabled for an unsupported #{resource_noun}")
      return
    end

    return if resource_addable_key?(@runner.runner_key)
    return if resource_container_executable_keys.include?(@runner.runner_key)

    @runner.errors.add(attribute, "cannot be enabled for a #{resource_noun} whose CLI is not installed in the agent container")
  end

  def toggle_partial_prefix
    legacy_provider_controller? ? "providers" : "runners"
  end

  def toggle_partial_locals_key
    legacy_provider_controller? ? :provider : :runner
  end

  def validate_container_executable!
    return if @runner.runner_key.blank?

    # On create, the model's inclusion validation catches unsupported keys.
    # On update, runner_key is immutable so that validation does not fire —
    # we must explicitly block enabling run/fallback flags for runners whose
    # key has been removed from the supported registry after creation.
    unless resource_supported_key?(@runner.runner_key)
      return if @runner.new_record?

      # Unlike the container-executable check below, unsupported runners
      # cannot function at all — block if either flag is true, regardless of
      # whether the user changed it in this request. The message tells the
      # user they need to disable the flag, not that they "cannot enable" it.
      if @runner.enabled_for_agent_runs
        @runner.errors.add(:enabled_for_agent_runs, "must be disabled for an unsupported #{resource_noun}")
      end
      if @runner.enabled_for_chat
        @runner.errors.add(:enabled_for_chat, "must be disabled for an unsupported #{resource_noun}")
      end
      if @runner.enabled_for_fallback
        @runner.errors.add(:enabled_for_fallback, "must be disabled for an unsupported #{resource_noun}")
      end
      return
    end

    return if resource_addable_key?(@runner.runner_key)

    setting_agent_runs = @runner.enabled_for_agent_runs && (@runner.new_record? || @runner.will_save_change_to_attribute?("enabled_for_agent_runs", to: true))
    setting_chat = @runner.enabled_for_chat && (@runner.new_record? || @runner.will_save_change_to_attribute?("enabled_for_chat", to: true))
    setting_fallback = @runner.enabled_for_fallback && (@runner.new_record? || @runner.will_save_change_to_attribute?("enabled_for_fallback", to: true))

    if setting_agent_runs
      @runner.errors.add(:enabled_for_agent_runs, "cannot be enabled for a #{resource_noun} whose CLI is not installed in the agent container")
    end
    if setting_chat
      @runner.errors.add(:enabled_for_chat, "cannot be enabled for a #{resource_noun} whose CLI is not installed in the agent container")
    end
    if setting_fallback
      @runner.errors.add(:enabled_for_fallback, "cannot be enabled for a #{resource_noun} whose CLI is not installed in the agent container")
    end
  end

  def reconcile_settings!
    settings = current_user.settings

    run_identifiers = ensure_run_enabled_runner_identifiers!
    return false if run_identifiers.blank?

    fallback_identifiers = fallback_candidate_runner_identifiers

    attrs = {
      fallback_runners: settings.sanitize_runner_tokens(settings.fallback_runners, candidates: fallback_identifiers),
      default_agent_runners_by_goal: sanitize_goal_default_runner_identifiers(settings, run_identifiers)
    }

    default_identifier = settings.default_runner_identifier
    attrs[:default_agent_runner] = run_identifiers.first unless default_identifier && run_identifiers.include?(default_identifier)

    return true if settings.update(attrs)

    Rails.logger.error(
      message: "runners.reconcile_settings_failed",
      user_id: current_user.id,
      errors: settings.errors.full_messages
    )
    false
  end

  def ensure_run_enabled_runner_identifiers!
    run_identifiers = enabled_agent_runner_identifiers
    return run_identifiers if run_identifiers.present?

    default_key = resource_default_key
    return [] unless default_key

    default = resource_records.kept_only.find_or_initialize_by(runner_key: default_key, auth_type: "subscription")
    default.enabled_for_agent_runs = true
    default.enabled_for_fallback = true if default.new_record?

    return enabled_agent_runner_identifiers if default.save

    Rails.logger.error(
      message: "runners.ensure_run_enabled_runner_failed",
      user_id: current_user.id,
      errors: default.errors.full_messages
    )
    []
  end

  def load_index_context
    @runners = policy_scope(resource_model_class).ordered
    @runner_states = cached_runner_states
    @user_setting = current_user.settings

    # Derive enabled/fallback identifiers from the already-loaded @runners
    # collection to avoid 2 extra queries.
    executable_keys = resource_container_executable_keys.to_set
    enabled_runners = @runners.select { |r| r.enabled_for_agent_runs? && executable_keys.include?(r.runner_key) }
    fallback_runners = @runners.select { |r| r.enabled_for_fallback? && executable_keys.include?(r.runner_key) }

    @enabled_agent_runners = UserSetting.runner_identifiers_for(enabled_runners, identifiers: true)
    @run_enabled_runners = run_enabled_runners_in_identifier_order(@enabled_agent_runners)
    @fallback_candidate_runners = UserSetting.runner_identifiers_for(fallback_runners, identifiers: true)
    @default_runner_identifier = @user_setting.default_runner_identifier
    @goal_runner_labels = {
      "create_pr" => "PR Agent",
      "review" => "Code Review Agent",
      "create_issue" => "Issue Agent"
    }
    @explicit_goal_default_runners = @user_setting.default_agent_runners_by_goal.slice(*AgentRun::GOALS)
    @saved_fallback_runner_tokens = @user_setting.sanitize_runner_tokens(
      @user_setting.fallback_runners,
      candidates: (@enabled_agent_runners + @fallback_candidate_runners).uniq
    )
    @runner_labels = @runners.each_with_object({}) do |runner, labels|
      labels[runner.routing_key] = runner.display_name
      labels[runner.runner_key] ||= runner.display_name
    end
    @subscription_runner_identifiers = @runners.select(&:subscription?).map(&:routing_key).to_set
    @runner_state_aliases = @runners.each_with_object({}) do |runner, aliases|
      aliases[runner.routing_key] = runner.runner_key
    end
    @usage_stats = resource_usage_stats_service.call(user: current_user)
    # Pre-index stats per runner to avoid duplicate lookups in views
    @runner_stats_by_id = @runners.each_with_object({}) do |runner, hash|
      stats = @usage_stats[runner.routing_key] || @usage_stats[runner.runner_key]
      hash[runner.id] = stats
    end
    @available_api_keys = current_user.provider_api_keys.ordered
    existing_subscription_keys = @runners.select(&:subscription?).map(&:runner_key)
    addable_keys = resource_addable_keys
    api_key_compatible_addable_keys =
      addable_keys.select do |key|
        @available_api_keys.any? { |api_key| compatible_api_key_for_runner?(api_key: api_key, runner_key: key) }
      end
    @addable_runner_options = (
      (addable_keys - existing_subscription_keys) + api_key_compatible_addable_keys
    ).uniq.presence || []
    assign_legacy_provider_index_ivars
  end

  def update_fallback_runner_flags!
    raw = params.dig(:user_setting, :enabled_fallback_runner_keys) ||
      params.dig(:user_setting, :enabled_fallback_provider_keys)
    return unless raw

    enabled_keys = UserSetting.normalize_fallback_runners_param(raw)
    # Treat empty result as "no change" to avoid disabling all runners on parse errors
    return if enabled_keys.blank?

    Runner.update_fallback_flags(current_user, enabled_keys)
  end

  def runner_settings_params
    permitted = params.require(:user_setting).permit(
      :default_agent_runner,
      :default_agent_provider,
      :fallback_enabled,
      :fallback_runners,
      :fallback_providers,
      :runner_selection_mode,
      :provider_selection_mode,
      default_agent_runners_by_goal: AgentRun::GOALS,
      default_agent_providers_by_goal: AgentRun::GOALS
    )

    if permitted.key?(:default_agent_provider) && !permitted.key?(:default_agent_runner)
      permitted[:default_agent_runner] = permitted.delete(:default_agent_provider)
    end
    if permitted.key?(:default_agent_providers_by_goal) && !permitted.key?(:default_agent_runners_by_goal)
      permitted[:default_agent_runners_by_goal] = permitted.delete(:default_agent_providers_by_goal)
    end
    if permitted.key?(:fallback_providers) && !permitted.key?(:fallback_runners)
      permitted[:fallback_runners] = permitted.delete(:fallback_providers)
    end
    if permitted.key?(:provider_selection_mode) && !permitted.key?(:runner_selection_mode)
      permitted[:runner_selection_mode] = permitted.delete(:provider_selection_mode)
    end

    permitted[:fallback_runners] = UserSetting.normalize_fallback_runners_param(permitted[:fallback_runners]) if permitted.key?(:fallback_runners)

    if permitted.key?(:runner_selection_mode) && permitted[:runner_selection_mode].present?
      mode = permitted[:runner_selection_mode].to_s
      if UserSetting::RUNNER_SELECTION_MODES.include?(mode)
        permitted[:runner_selection_mode] = mode
      else
        permitted.delete(:runner_selection_mode)
      end
    end

    expand_combined_runner_mode!(permitted)

    permitted
  end

  # Parses the combined runner_mode param into runner_selection_mode
  # and default_agent_runner. Values are either "single:<identifier>"
  # for a specific runner, or "round_robin"/"random" for multi-runner
  # distribution.
  def expand_combined_runner_mode!(permitted)
    combined = params.dig(:user_setting, :runner_mode).presence ||
      params.dig(:user_setting, :provider_mode).presence
    combined = combined.to_s.strip
    return if combined.blank?

    if combined.start_with?("single:")
      runner_identifier = combined.delete_prefix("single:")
      permitted[:runner_selection_mode] = "single"
      permitted[:default_agent_runner] = runner_identifier
    elsif UserSetting::RUNNER_SELECTION_MODES.include?(combined)
      permitted[:runner_selection_mode] = combined
    end
  end

  # Applies per-runner weight updates from form params. Each entry must
  # be a positive integer; invalid values flash a single error and abort
  # the settings save so the user sees the failure rather than a silent
  # partial update.
  def update_runner_weights!
    raw = params.dig(:user_setting, :runner_weights) ||
      params.dig(:user_setting, :provider_weights)
    return true if raw.blank?

    weights = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    invalid = false
    Runner.transaction do
      weights.each do |runner_id, weight_value|
        runner = current_user.runners.kept_only.find_by(id: runner_id)
        next unless runner

        coerced = Integer(weight_value, exception: false)
        if coerced.nil? || coerced < 1 || coerced > Runner::MAX_WEIGHT
          @user_setting.errors.add(:base, "#{runner.display_name} weight must be an integer between 1 and #{Runner::MAX_WEIGHT}")
          invalid = true
          raise ActiveRecord::Rollback
        end

        next if runner.weight == coerced

        unless runner.update(weight: coerced)
          @user_setting.errors.add(:base, "#{runner.display_name} weight: #{runner.errors.full_messages.to_sentence}")
          invalid = true
          raise ActiveRecord::Rollback
        end
      end
    end

    !invalid
  end

  def cached_runner_states
    Rails.cache.fetch("runners/states/#{current_user.id}", expires_in: 30.seconds) do
      resource_states.each_with_object({}) do |state, hash|
        hash[state.runner_name] = CachedState.new(
          circuit_state: state.circuit_state,
          rate_limited_until: state.rate_limited_until
        )
      end
    end
  end

  def compatible_api_key_for_runner?(api_key:, runner_key:)
    # Direct-outbound runners support multiple API key types depending on the
    # selected api_provider, so check against all compatible service types.
    if %w[opencode kilocode aider].include?(runner_key)
      return resource_model_class::DIRECT_OUTBOUND_SERVICE_TYPES.include?(api_key.api_service_type)
    end
    if runner_key == "pi"
      return resource_model_class::PI_API_PROVIDERS.values.any? { |config| config[:service_type] == api_key.api_service_type }
    end

    api_key.api_service_type == resource_api_service_type_for(runner_key)
  end

  def enabled_agent_runner_identifiers
    return legacy_enabled_agent_provider_identifiers if legacy_provider_controller?

    executable_keys = resource_container_executable_keys
    runners = resource_records.kept_only.for_agent_runs.where(runner_key: executable_keys).ordered
    UserSetting.runner_identifiers_for(runners, identifiers: true)
  end

  def legacy_enabled_agent_provider_identifiers
    tokens = UserSetting.enabled_agent_providers(current_user)
    return [] if tokens.blank?

    providers = resource_records.kept_only.for_agent_runs.ordered.to_a
    tokens.filter_map do |token|
      next token if Provider.routing_key?(token)

      providers.find { |provider| provider.matches_identifier?(token) }&.routing_key
    end
  end

  # Returns Runner records corresponding to the given routing-key
  # identifiers, preserving the identifier order so the settings UI can
  # render weight rows in the same order as the rest of the page.
  def run_enabled_runners_in_identifier_order(identifiers)
    return [] if identifiers.blank?

    ids = identifiers.filter_map { |identifier| Runner.id_from_routing_key(identifier) }
    runners_by_id = resource_records.kept_only.where(id: ids).index_by(&:id)
    ids.filter_map { |id| runners_by_id[id] }
  end

  def fallback_candidate_runner_identifiers
    executable_keys = resource_container_executable_keys
    runners = resource_records.kept_only.for_fallback.where(runner_key: executable_keys).ordered
    UserSetting.runner_identifiers_for(runners, identifiers: true)
  end

  def sanitize_goal_default_runner_identifiers(settings, candidates)
    AgentRun::GOALS.each_with_object({}) do |goal, normalized|
      token = settings.default_agent_runners_by_goal[goal]
      next if token.blank?

      resolved = settings.sanitize_runner_tokens([ token ], candidates: candidates)
      next if resolved.blank?

      normalized[goal] = resolved.first
    end
  end

  def goal_default_runner_attrs(attrs)
    submitted = attrs[:default_agent_runners_by_goal]
    return sanitize_goal_default_runner_identifiers(@user_setting, enabled_agent_runner_identifiers) unless submitted

    raw_submitted = params.dig(:user_setting, :default_agent_runners_by_goal) ||
      params.dig(:user_setting, :default_agent_providers_by_goal)
    return sanitize_goal_default_runner_identifiers(@user_setting, enabled_agent_runner_identifiers) if submitted.empty? && raw_goal_defaults_filtered_out?(raw_submitted)

    submitted
  end

  def raw_goal_defaults_filtered_out?(raw_submitted)
    return true unless raw_submitted.respond_to?(:keys)

    raw_submitted.keys.map(&:to_s).intersection(AgentRun::GOALS).empty?
  end

  def legacy_provider_controller?
    controller_name == "providers"
  end

  def resource_param_key
    return :provider if params.key?(:provider)

    :runner
  end

  def resource_index_path
    legacy_provider_controller? ? providers_path : runners_path
  end

  def resource_created_notice
    legacy_provider_controller? ? "Provider created successfully." : "Runner created successfully."
  end

  def resource_updated_notice
    legacy_provider_controller? ? "Provider updated successfully." : "Runner updated successfully."
  end

  def resource_deleted_notice
    legacy_provider_controller? ? "Provider deleted successfully." : "Runner deleted successfully."
  end

  def resource_settings_saved_notice
    legacy_provider_controller? ? "Provider settings saved successfully." : "Runner settings saved successfully."
  end

  def resource_reconciliation_alert(action:)
    resource_name = legacy_provider_controller? ? "Provider" : "Runner"
    "#{resource_name} #{action}, but settings reconciliation failed. Please review settings."
  end

  def resource_model_class
    legacy_provider_controller? ? Provider : Runner
  end

  def resource_records
    legacy_provider_controller? ? current_user.providers : current_user.runners
  end

  def resource_states
    legacy_provider_controller? ? current_user.provider_states : current_user.runner_states
  end

  def resource_usage_stats_service
    legacy_provider_controller? ? Providers::UsageStats : Runners::UsageStats
  end

  def resource_test_agent_service
    legacy_provider_controller? ? Providers::TestAgent : Runners::TestAgent
  end

  def resource_test_agent_arguments
    legacy_provider_controller? ? { provider: @runner } : { runner: @runner }
  end

  def resource_container_executable_keys
    legacy_provider_controller? ? ProviderSupport.container_executable_provider_keys : RunnerSupport.container_executable_runner_keys
  end

  def resource_noun
    legacy_provider_controller? ? "provider" : "runner"
  end

  def resource_addable_keys
    legacy_provider_controller? ? Provider.addable_provider_keys : Runner.addable_runner_keys
  end

  def resource_addable_key?(runner_key)
    legacy_provider_controller? ? Provider.addable_provider_key?(runner_key) : Runner.addable_runner_key?(runner_key)
  end

  def resource_supported_key?(runner_key)
    legacy_provider_controller? ? Provider.supported_provider_key?(runner_key) : Runner.supported_runner_key?(runner_key)
  end

  def resource_api_service_type_for(runner_key)
    legacy_provider_controller? ? Provider.api_service_type_for(runner_key) : Runner.api_service_type_for(runner_key)
  end

  def resource_default_key
    legacy_provider_controller? ? ProviderSupport.container_executable_provider_keys.first : Runner.default_runner_key
  end

  def translated_resource_errors(message)
    return message unless legacy_provider_controller?

    message.gsub("last runner enabled for agent runs", "last provider enabled for agent runs")
  end

  def assign_legacy_provider_ivars(record)
    return unless legacy_provider_controller?

    @provider = record
  end

  def assign_legacy_provider_option_ivars
    return unless legacy_provider_controller?

    @subscription_provider_options = @subscription_runner_options
    @api_key_provider_options = @api_key_runner_options
  end

  def assign_legacy_provider_index_ivars
    return unless legacy_provider_controller?

    @providers = @runners
    @provider_states = @runner_states
    @enabled_agent_providers = @enabled_agent_runners
    @run_enabled_providers = @run_enabled_runners
    @fallback_candidate_providers = @fallback_candidate_runners
    @default_provider_identifier = @default_runner_identifier
    @goal_provider_labels = @goal_runner_labels
    @explicit_goal_default_providers = @explicit_goal_default_runners
    @saved_fallback_provider_tokens = @saved_fallback_runner_tokens
    @provider_labels = @runner_labels
    @subscription_provider_identifiers = @subscription_runner_identifiers
    @provider_state_aliases = @runner_state_aliases
    @provider_stats_by_id = @runner_stats_by_id
    @addable_provider_options = @addable_runner_options
  end
end
