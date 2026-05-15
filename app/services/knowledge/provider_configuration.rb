# frozen_string_literal: true

module Knowledge
  class ProviderConfiguration < RunnerConfiguration
    Result = RunnerConfiguration::Result

    def self.for_embedding_candidate_providers(project:)
      new(project:).for_embedding_candidate_providers
    end

    def for_embedding_candidate_providers
      for_embedding_candidates
    end
  end
end
