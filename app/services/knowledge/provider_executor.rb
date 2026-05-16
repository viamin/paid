# frozen_string_literal: true

module Knowledge
  class ProviderExecutor < RunnerExecutor
    AllProvidersExhausted = RunnerExecutor::AllRunnersExhausted

    def execute
      super
    rescue RunnerExecutor::AllRunnersExhausted => error
      raise AllProvidersExhausted, translate_exhaustion_message(error.message)
    end

    private

    def available_runners
      case @operation.to_sym
      when :embedding
        Knowledge::ProviderSelector.for_embedding(user_setting: @user_setting)
      when :chat
        Knowledge::ProviderSelector.for_chat(user_setting: @user_setting)
      else
        raise ArgumentError, "Unsupported operation: #{@operation}"
      end
    end

    def runner_state_for(runner)
      @runner_states ||= {}
      @runner_states[runner] ||= @user_setting.user
        .provider_states
        .find_or_create_by!(provider_name: runner) do |state|
          state.circuit_state = "closed"
          state.failure_count = 0
        end
    end

    def log_runner_failure(runner, reason, error)
      Rails.logger.warn(
        message: "knowledge.provider_failure",
        operation: @operation.to_s,
        provider: runner,
        reason: reason,
        error_class: error.class.name,
        error: error.message,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      )
    end

    def log_runner_switch(from_runner, to_runner, reason, error)
      return if to_runner.blank?

      Rails.logger.warn(
        message: "knowledge.provider_switch",
        operation: @operation.to_s,
        from_provider: from_runner,
        to_provider: to_runner,
        reason: reason,
        error_class: error.class.name,
        error: error.message,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      )
    end

    def log_runners_unavailable(reason, error: nil)
      payload = {
        message: "knowledge.providers_unavailable",
        operation: @operation.to_s,
        reason: translate_unavailable_reason(reason),
        providers: available_runners_for_logging,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      }
      payload[:error_class] = error.class.name if error
      payload[:error] = error.message if error

      Rails.logger.warn(payload)
    end

    def available_runners_for_logging
      case @operation.to_sym
      when :embedding
        configured_runners(:kb_embedding_provider, :kb_embedding_fallback_providers)
      when :chat
        configured_runners(:kb_chat_provider, :kb_chat_fallback_providers)
      else
        []
      end
    end

    def translate_unavailable_reason(reason)
      case reason
      when "no_available_runners" then "no_available_providers"
      when "all_runners_exhausted" then "all_providers_exhausted"
      else reason.to_s.gsub("runner", "provider")
      end
    end

    def translate_exhaustion_message(message)
      message.to_s.gsub("runners", "providers").gsub("runner", "provider")
    end
  end
end
