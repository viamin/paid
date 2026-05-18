# frozen_string_literal: true

module Knowledge
  class RunnerSelector
    def self.for_embedding(user_setting:)
      new(user_setting:).runners_for(:embedding)
    end

    def self.for_chat(user_setting:)
      new(user_setting:).runners_for(:chat)
    end

    def initialize(user_setting:)
      @user_setting = user_setting
    end

    def runners_for(operation)
      candidates = configured_runners_for(operation)
      warn_on_embedding_fallback(candidates) if operation.to_sym == :embedding

      runner_states = user_setting.user.runner_states.where(runner_name: candidates).index_by(&:runner_name)

      candidates.select do |runner|
        runner_available?(runner, runner_states)
      end
    end

    private

    attr_reader :user_setting

    def configured_runners_for(operation)
      runners = configured_runner_values_for(operation).filter_map do |runner|
        runner.to_s.strip.downcase.presence
      end.uniq

      filter_supported_runners(runners, operation: operation)
    end

    def configured_runner_values_for(operation)
      case operation.to_sym
      when :embedding
        [ user_setting.kb_embedding_runner, *Array(user_setting.kb_embedding_fallback_runners) ]
      when :chat
        [ user_setting.kb_chat_runner, *Array(user_setting.kb_chat_fallback_runners) ]
      else
        raise ArgumentError, "Unsupported knowledge runner operation: #{operation}"
      end
    end

    def filter_supported_runners(runners, operation:)
      supported = supported_runners_for(operation)
      unsupported = runners - supported
      log_unsupported_runners(operation, unsupported) if unsupported.any?

      runners - unsupported
    end

    def supported_runners_for(operation)
      case operation.to_sym
      when :embedding
        UserSetting::KB_EMBEDDING_RUNNERS
      when :chat
        UserSetting::KB_CHAT_RUNNERS
      else
        raise ArgumentError, "Unsupported knowledge runner operation: #{operation}"
      end
    end

    def runner_available?(runner, runner_states)
      state = runner_states[runner]
      return true unless state

      state.check_circuit_recovery!(timeout: user_setting.circuit_breaker_timeout_seconds)
      !state.unavailable?
    end

    def warn_on_embedding_fallback(candidates)
      return unless candidates.size > 1

      Rails.logger.warn(
        message: "knowledge.runner_selector.embedding_fallback_requires_compatible_model",
        user_setting_id: user_setting.id,
        runners: candidates,
        model: Knowledge::Embeddings::Generate::MODEL,
        dimensions: Knowledge::Embeddings::Generate::DIMENSIONS
      )
    end

    def log_unsupported_runners(operation, runners)
      Rails.logger.warn(
        message: "knowledge.runner_selector.unsupported_runner_configured",
        user_setting_id: user_setting.id,
        operation: operation.to_sym,
        runners: runners
      )
    end
  end
end
