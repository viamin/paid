# frozen_string_literal: true

require_relative "runner_support"

# Thin delegation layer to RunnerSupport for backward compatibility.
# ProviderSupport and RunnerSupport are functionally equivalent after the
# provider→runner rename, except that the provider surface excludes the
# runner-only "omp" key ("pi" stays provider-side). This module eliminates
# duplication by delegating to RunnerSupport while maintaining the
# provider-key naming convention and the narrower key set at the call sites.

module ProviderSupport
  # Provider-side sets are the runner-side sets minus the runner-only "omp".
  APP_PROVIDER_KEYS = (RunnerSupport::APP_RUNNER_KEYS - %w[omp]).freeze
  CONTAINER_EXECUTABLE_PROVIDER_KEYS = Set.new(RunnerSupport::CONTAINER_EXECUTABLE_RUNNER_KEYS - %w[omp]).freeze
  MAX_RATE_LIMIT_RESET_SECONDS = RunnerSupport::MAX_RATE_LIMIT_RESET_SECONDS

  # Shared constants
  API_SERVICE_TYPES = RunnerSupport::API_SERVICE_TYPES
  PROVIDER_API_SERVICE_TYPE = RunnerSupport::RUNNER_API_SERVICE_TYPE
  API_SERVICE_TYPE_TO_HARNESS_KEY = RunnerSupport::API_SERVICE_TYPE_TO_HARNESS_KEY
  PROXY_HEALTH_CHECK_API_KEYS = RunnerSupport::PROXY_HEALTH_CHECK_API_KEYS
  PROVIDER_BOT_USERNAMES = RunnerSupport::RUNNER_BOT_USERNAMES
  PROXY_HEADER_UNSET_VARS = RunnerSupport::PROXY_HEADER_UNSET_VARS
  HARNESS_RUNTIME_UNSET_VARS = RunnerSupport::HARNESS_RUNTIME_UNSET_VARS

  module_function

  def supported_provider_keys
    RunnerSupport.supported_runner_keys & APP_PROVIDER_KEYS
  end

  def supported_provider_key?(provider_key)
    APP_PROVIDER_KEYS.include?(provider_key.to_s) && RunnerSupport.supported_runner_key?(provider_key)
  end

  def supported_provider_keys_set
    RunnerSupport.supported_runner_keys_set & APP_PROVIDER_KEYS
  end

  def reset_supported_provider_keys!
    RunnerSupport.reset_supported_runner_keys!
  end

  def container_executable_provider_keys
    supported_provider_keys.select { |key| CONTAINER_EXECUTABLE_PROVIDER_KEYS.include?(key) }
  end

  def container_executable_provider_key?(provider_key)
    container_executable_provider_keys.include?(provider_key.to_s)
  end

  def addable_provider_keys
    container_executable_provider_keys
  end

  def addable_provider_key?(provider_key)
    addable_provider_keys.include?(provider_key.to_s)
  end

  def harness_provider_key_for(provider_key)
    RunnerSupport.harness_runner_key_for(provider_key)
  end

  def provider_key_for_agent_type(agent_type)
    RunnerSupport.runner_key_for_agent_type(agent_type)
  end

  def agent_type_for(provider_key)
    RunnerSupport.agent_type_for(provider_key)
  end

  def api_service_types
    RunnerSupport.api_service_types
  end

  def api_service_type_for(provider_key)
    RunnerSupport.api_service_type_for(provider_key)
  end

  def api_service_type_label(service_type)
    RunnerSupport.api_service_type_label(service_type)
  end

  def subscription_auth_unset_vars_for(provider_key)
    RunnerSupport.subscription_auth_unset_vars_for(provider_key)
  end

  def subscription_auth_unset_vars
    RunnerSupport.subscription_auth_unset_vars
  end

  def proxy_health_check_api_key_for(provider_key)
    RunnerSupport.proxy_health_check_api_key_for(provider_key)
  end

  def provider_bot_username?(login)
    RunnerSupport.runner_bot_username?(login)
  end

  def all_bot_usernames
    RunnerSupport.all_bot_usernames
  end

  def provider_key_for_bot_username(login)
    RunnerSupport.runner_key_for_bot_username(login)
  end

  def provider_bot_usernames_for(provider_key)
    RunnerSupport.runner_bot_usernames_for(provider_key)
  end

  def provider_bot_username_for?(provider_key, login)
    RunnerSupport.runner_bot_username_for?(provider_key, login)
  end

  def harness_provider_for_api_service_type(api_service_type)
    RunnerSupport.harness_provider_for_api_service_type(api_service_type)
  end

  def harness_runtime_unset_vars_for(provider_key)
    RunnerSupport.harness_runtime_unset_vars_for(provider_key)
  end

  def command_with_unset_env(command, unset_vars)
    RunnerSupport.command_with_unset_env(command, unset_vars)
  end

  def harness_provider_for(provider_key)
    RunnerSupport.harness_for(provider_key)
  end

  def normalized_rate_limit_reset_text(text)
    RunnerSupport.normalized_rate_limit_reset_text(text)
  end

  def rate_limit_reset_at(harness_provider, text)
    RunnerSupport.rate_limit_reset_at(harness_provider, text)
  end

  def error_classification_patterns_for(provider_key, category)
    RunnerSupport.error_classification_patterns_for(provider_key, category)
  end

  def aggregated_error_classification_patterns(category)
    RunnerSupport.aggregated_error_classification_patterns(category)
  end

  def aggregated_noisy_error_patterns
    RunnerSupport.aggregated_noisy_error_patterns
  end

  def translate_provider_error(provider_key, message)
    RunnerSupport.translate_runner_error(provider_key, message)
  end
end
