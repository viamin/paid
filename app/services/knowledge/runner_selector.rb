# frozen_string_literal: true

module Knowledge
  class RunnerSelector
    def self.for_embedding(user_setting:)
      new(user_setting:).runners_for(:embedding)
    end

    def self.for_chat(user_setting:)
      new(user_setting:).runners_for(:chat)
    end

    def self.for_issue_analysis(user_setting:)
      new(user_setting:).runners_for(:issue_analysis)
    end

    # Broadens chat selection beyond the kb_chat settings to every
    # chat-enabled Runner the user owns, applying the same circuit-breaker /
    # rate-limit availability filter as #runners_for. Used when the
    # settings-based selection yields no candidates because the configured
    # runner is currently unavailable (rate-limited / circuit-open).
    def self.available_chat_runner_keys(user_setting:)
      new(user_setting:).available_chat_runner_keys
    end

    def self.available_standalone_chat_runner_keys(user_setting:, preferred_identifiers: nil)
      new(user_setting:).available_standalone_chat_runner_keys(preferred_identifiers:)
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

    # Chat runner keys derived from the user's actual Runner records (not just
    # the kb_chat settings), filtered to supported chat runners and to those
    # that are currently available. Returns keys in runner priority order.
    #
    # @spec ISSUE-ANALYSIS-002
    def available_chat_runner_keys
      # .uniq matches configured_runners_for: an owner can hold several
      # api_key Runner rows for the same key (e.g. two opencode accounts),
      # and each provider should only be attempted once.
      candidate_keys = user_setting.user.runners.kept_only.for_chat.ordered.pluck(:runner_key).uniq
      filtered = filter_supported_runners(candidate_keys, operation: :chat)
      runner_states = user_setting.user.runner_states.where(runner_name: filtered).index_by(&:runner_name)
      filtered.select { |runner| runner_available?(runner, runner_states) }
    end

    # @spec ISSUE-ANALYSIS-002 LLM-ROUTING-005
    # Returns routing keys rather than provider keys so Llm::Request receives
    # the exact owned credential selected for a host text request.
    def available_standalone_chat_runner_keys(preferred_identifiers: nil)
      runners = standalone_chat_runners
      preferred = Array(preferred_identifiers).filter_map { |identifier| identifier.to_s.presence }
      runners = runners.select { |runner| preferred_runner?(runner, preferred) } if preferred.any?

      states = user_setting.user.runner_states.where(runner_name: runners.map(&:state_key)).index_by(&:runner_name)
      capable = runners.select { |runner| standalone_text_capable?(runner) && runner_available?(runner.state_key, states) }
      ordered_standalone_runners(capable, preferred).map(&:routing_key)
    end

    private

    attr_reader :user_setting

    def configured_runners_for(operation)
      runners = configured_runner_values_for(operation).filter_map do |runner|
        runner.to_s.strip.downcase.presence
      end.uniq

      filter_supported_runners(runners, operation: operation)
    end

    def standalone_chat_runners
      user_setting.user.runners.kept_only.for_chat.includes(:provider_api_key, :integration_credential).ordered
        .select { |runner| supported_runners_for(:issue_analysis).include?(runner.runner_key) }
    end

    def preferred_runner?(runner, identifiers)
      identifiers.include?(runner.routing_key) || identifiers.include?(runner.runner_key)
    end

    def standalone_text_capable?(runner)
      return runner.effective_api_secret.present? if runner.api_key?
      return false unless runner.subscription?
      return false if managed_subscription?(runner)

      standalone_driver_supports_tool_control?(runner)
    end

    def managed_subscription?(runner)
      user_setting.user.account.runner_credentials.for_runner(runner.runner_key).where(revoked_at: nil).exists?
    end

    def standalone_driver_supports_tool_control?(runner)
      key = RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym
      AgentHarness.provider_class(key).new(config: AgentHarness.build_config(key)).supports_tool_control?
    rescue AgentHarness::ConfigurationError, KeyError
      false
    end

    def ordered_standalone_runners(runners, preferred)
      return runners.sort_by { |runner| [ RunnerSupport.lean_runner?(runner.runner_key) ? 0 : 1, runner.runner_key, runner.id ] } if preferred.empty?

      runners.sort_by { |runner| [ preferred.index(runner.routing_key) || preferred.index(runner.runner_key), runner.id ] }
    end

    def configured_runner_values_for(operation)
      case operation.to_sym
      when :embedding
        [ user_setting.kb_embedding_runner, *Array(user_setting.kb_embedding_fallback_runners) ]
      when :chat
        [ user_setting.kb_chat_runner, *Array(user_setting.kb_chat_fallback_runners) ]
      when :issue_analysis
        [ user_setting.issue_analysis_runner, *Array(user_setting.issue_analysis_fallback_runners) ]
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
      when :chat, :issue_analysis
        UserSetting::KB_CHAT_RUNNERS + user_setting.user.runners.kept_only.for_chat.map(&:routing_key)
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
        model: embedding_model,
        dimensions: embedding_dimensions
      )
    end

    # Returns the user-configured embedding model id, falling back to the
    # bundled default. Centralized so the warn-log message reflects the
    # actual model the pipeline will request — not the legacy constant.
    def embedding_model
      user_setting.kb_embedding_model.presence || Knowledge::Embeddings::Generate::DEFAULT_MODEL
    end

    def embedding_dimensions
      user_setting.kb_embedding_dimensions
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
