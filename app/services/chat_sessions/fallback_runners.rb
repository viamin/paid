# frozen_string_literal: true

require "set"

module ChatSessions
  module FallbackRunners
    module_function

    def for(chat_session:, excluding: [])
      # @spec CHAT-API-006
      user = chat_session.created_by
      return [] unless user&.settings

      excluded_ids = excluded_runner_ids(excluding)
      excluded_ids << chat_session.runner_id if excluding.blank? && chat_session.runner_id.present?
      current_runner = chat_session.reload.runner
      current_candidates = if usable_runner?(current_runner) && !excluded_ids.include?(current_runner.id)
        [ current_runner ]
      else
        []
      end

      configured_candidates = Array(user.settings.kb_chat_fallback_runners).filter_map do |identifier|
        runner = runner_for_identifier(user, identifier, excluding_ids: excluded_ids)
        next unless usable_runner?(runner)
        next if excluded_ids.include?(runner.id)

        runner
      end

      automatic_candidates = user.runners.kept_only.for_fallback.api_key
        .includes(:provider_api_key, :integration_credential)
        .for_chat.ordered.filter_map do |runner|
        next unless usable_runner?(runner)
        next if excluded_ids.include?(runner.id)

        runner
      end

      (current_candidates + configured_candidates + automatic_candidates).uniq.select do |runner|
        free_pool_available?(runner, chat_session: chat_session)
      end
    end

    def switch!(chat_session:, runner:)
      model = if runner.free_model_policy?
        FreeModels::SelectChatModel.for_session(runner: runner, chat_session: chat_session).model_id
      else
        model_for(runner)
      end
      chat_session.update!(runner: runner, model: model)
    end

    # @spec CHAT-API-019
    def free_pool_available?(runner, chat_session:)
      return true unless runner.free_model_policy?

      FreeModels::SelectChatModel.for_session(runner: runner, chat_session: chat_session)
      true
    rescue LlmClientConfigurationError
      false
    end

    # @spec CHAT-API-018
    def model_for(runner, project: nil)
      return FreeModels::SelectChatModel.call(runner: runner, project: project).model_id if runner.free_model_policy?

      runner.direct_outbound_model_id.presence || default_model_for_service_type(service_type_for(runner))
    end

    def notice_for(error:, runner:)
      reason = if error.is_a?(AgentHarness::RateLimitError)
        "hit a rate limit"
      else
        "could not complete the request"
      end

      "The selected chat runner #{reason}: #{ErrorMessage.for(error)} Switching to #{runner.display_name} and continuing."
    end

    def usable_runner?(runner)
      BuildLlmClient.usable_runner?(runner)
    end

    # @spec RUNNER-USAGE-006
    # Chat fallback requires both the chat usage permission and the fallback
    # modifier — fallback never unlocks chat on its own.
    def runner_for_identifier(user, identifier, excluding_ids:)
      if Runner.routing_key?(identifier)
        runner = Runner.for_identifier(user, identifier)
        return nil if runner && excluding_ids.include?(runner.id)
        return nil unless runner&.enabled_for_chat?
        return nil unless runner&.enabled_for_fallback?

        runner
      else
        user.runners.kept_only.for_chat.for_fallback.where(runner_key: identifier).ordered.find do |runner|
          usable_runner?(runner) && !excluding_ids.include?(runner.id)
        end
      end
    end

    def excluded_runner_ids(runners)
      Array(runners).each_with_object(Set.new) do |runner, ids|
        next unless runner

        ids << runner.id
      end
    end

    def service_type_for(runner)
      runner.provider_api_key&.api_service_type || runner.required_api_service_type
    end

    def default_model_for_service_type(service_type)
      BuildLlmClient.default_model_for_service_type(service_type)
    end
  end
end
