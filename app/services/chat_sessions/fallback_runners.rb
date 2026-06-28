# frozen_string_literal: true

require "set"

module ChatSessions
  module FallbackRunners
    module_function

    def for(chat_session:, excluding: [])
      user = chat_session.created_by
      return [] unless user&.settings

      excluded_ids = excluded_runner_ids(excluding)

      Array(user.settings.kb_chat_fallback_runners).filter_map do |identifier|
        runner = runner_for_identifier(user, identifier, excluding_ids: excluded_ids)
        next unless usable_runner?(runner)
        next if excluded_ids.include?(runner.id)

        runner
      end.uniq
    end

    def switch!(chat_session:, runner:)
      chat_session.update!(runner: runner, model: model_for(runner))
    end

    def model_for(runner)
      runner.direct_outbound_model_id.presence || default_model_for_service_type(service_type_for(runner))
    end

    def notice_for(error:, runner:)
      "The selected chat runner hit a rate limit: #{ErrorMessage.for(error)} Switching to #{runner.display_name} and continuing."
    end

    def usable_runner?(runner)
      runner&.enabled_for_chat? && runner.effective_api_secret.present?
    end

    def runner_for_identifier(user, identifier, excluding_ids:)
      if Runner.routing_key?(identifier)
        Runner.for_identifier(user, identifier)
      else
        user.runners.kept_only.where(runner_key: identifier).ordered.find do |runner|
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
      return AgentHarness::TextTransport::DEFAULT_MODEL if service_type == BuildLlmClient::ANTHROPIC_SERVICE_TYPE

      "gpt-4o"
    end
  end
end
