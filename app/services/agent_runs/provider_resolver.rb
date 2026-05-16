# frozen_string_literal: true

module AgentRuns
  class ProviderResolver < RunnerResolver
    def self.call(**kwargs)
      new(**normalize_legacy_kwargs(kwargs)).call
    end

    def self.selected_provider(project:, provider_id:)
      selected_runner(project: project, runner_id: provider_id)
    end

    def self.normalize_legacy_kwargs(kwargs)
      normalized = kwargs.dup
      requested_provider_id = normalized.delete(:requested_provider_id)
      normalized[:requested_runner_id] ||= requested_provider_id
      normalized
    end

    def initialize(**kwargs)
      super(**self.class.normalize_legacy_kwargs(kwargs))
    end

    private

    def container_executable_runner_keys
      ProviderSupport.container_executable_provider_keys
    end

    def container_executable_runner_key?(runner_key)
      ProviderSupport.container_executable_provider_key?(runner_key)
    end

    def runner_key_for_agent_type(agent_type)
      ProviderSupport.provider_key_for_agent_type(agent_type)
    end

    def agent_type_for_runner_key(runner_key)
      ProviderSupport.agent_type_for(runner_key)
    end
  end
end
