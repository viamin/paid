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
      normalized[:requested_runner_id] ||= normalized.delete(:requested_provider_id)
      normalized
    end

    def initialize(**kwargs)
      super(**self.class.normalize_legacy_kwargs(kwargs))
    end
  end
end
