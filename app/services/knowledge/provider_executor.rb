# frozen_string_literal: true

module Knowledge
  # Wraps LLM calls with provider fallback iteration.
  #
  # Tries each available provider in priority order (primary, then fallbacks).
  # On rate-limit or provider errors, records the failure in ProviderState and
  # moves to the next provider. On success, records success and updates the
  # KnowledgeRun with the final provider.
  class ProviderExecutor
    class AllProvidersExhausted < StandardError; end

    def initialize(user_setting:, operation:, knowledge_run: nil)
      @user_setting = user_setting
      @operation = operation
      @knowledge_run = knowledge_run
    end

    def execute
      providers = available_providers
      if providers.empty?
        log_providers_unavailable("no_available_providers")
        raise AllProvidersExhausted, "No available providers for #{@operation}"
      end

      last_error = nil

      providers.each_with_index do |provider, index|
        record_attempt(provider)

        begin
          result = yield(provider)
          record_success(provider)
          return result
        rescue AgentHarness::RateLimitError => e
          record_rate_limit(provider, e)
          log_provider_failure(provider, "rate_limited", e)
          log_provider_switch(provider, providers[index + 1], "rate_limited", e)
          last_error = e
          next
        rescue AgentHarness::Error => e
          record_failure(provider, e)
          log_provider_failure(provider, "provider_error", e)
          log_provider_switch(provider, providers[index + 1], "provider_error", e)
          last_error = e
          next
        end
      end

      log_providers_unavailable("all_providers_exhausted", error: last_error)
      raise AllProvidersExhausted, "All providers exhausted for #{@operation}: #{last_error&.message}"
    end

    private

    def record_attempt(provider)
      @knowledge_run&.record_provider_attempt(provider)
    end

    def record_success(provider)
      @knowledge_run&.update!(final_provider: provider)
      provider_state_for(provider)&.record_success!
    end

    def record_rate_limit(provider, error)
      reset_at = error.respond_to?(:reset_time) ? error.reset_time : nil
      state = provider_state_for(provider)
      state&.mark_rate_limited!(reset_at: reset_at)
    end

    def record_failure(provider, _error)
      state = provider_state_for(provider)
      state&.record_failure!(threshold: @user_setting.circuit_breaker_failure_threshold)
    end

    def available_providers
      case @operation.to_sym
      when :embedding
        Knowledge::ProviderSelector.for_embedding(user_setting: @user_setting)
      when :chat
        Knowledge::ProviderSelector.for_chat(user_setting: @user_setting)
      else
        raise ArgumentError, "Unsupported operation: #{@operation}"
      end
    end

    def provider_state_for(provider)
      @provider_states ||= {}
      @provider_states[provider] ||= @user_setting.user
        .provider_states
        .find_or_create_by!(provider_name: provider) { |s|
          s.circuit_state = "closed"
          s.failure_count = 0
        }
    end

    def log_provider_failure(provider, reason, error)
      Rails.logger.warn(
        message: "knowledge.provider_failure",
        operation: @operation.to_s,
        provider: provider,
        reason: reason,
        error_class: error.class.name,
        error: error.message,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      )
    end

    def log_provider_switch(from_provider, to_provider, reason, error)
      return if to_provider.blank?

      Rails.logger.warn(
        message: "knowledge.provider_switch",
        operation: @operation.to_s,
        from_provider: from_provider,
        to_provider: to_provider,
        reason: reason,
        error_class: error.class.name,
        error: error.message,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      )
    end

    def log_providers_unavailable(reason, error: nil)
      payload = {
        message: "knowledge.providers_unavailable",
        operation: @operation.to_s,
        reason: reason,
        providers: available_providers_for_logging,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      }
      payload[:error_class] = error.class.name if error
      payload[:error] = error.message if error

      Rails.logger.warn(payload)
    end

    def available_providers_for_logging
      case @operation.to_sym
      when :embedding
        configured_providers(:kb_embedding_provider, :kb_embedding_fallback_providers)
      when :chat
        configured_providers(:kb_chat_provider, :kb_chat_fallback_providers)
      else
        []
      end
    end

    def configured_providers(primary_key, fallback_key)
      [ @user_setting.public_send(primary_key), *Array(@user_setting.public_send(fallback_key)) ]
        .filter_map { |provider| provider.to_s.strip.downcase.presence }
        .uniq
    end
  end
end
