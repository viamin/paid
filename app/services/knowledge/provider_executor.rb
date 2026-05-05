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

    def execute(&block)
      providers = available_providers
      raise AllProvidersExhausted, "No available providers for #{@operation}" if providers.empty?

      last_error = nil

      providers.each do |provider|
        record_attempt(provider)

        begin
          result = block.call(provider)
          record_success(provider)
          return result
        rescue AgentHarness::RateLimitError => e
          record_rate_limit(provider, e)
          last_error = e
          next
        rescue AgentHarness::Error => e
          record_failure(provider, e)
          last_error = e
          next
        end
      end

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
  end
end
