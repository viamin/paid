# frozen_string_literal: true

module QualityMetrics
  class CollectMutationScore
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      results = MutantResultsReader.read(agent_run.worktree_path)
      return nil unless results

      total = results.fetch(:total_mutations)
      killed = results.fetch(:killed_mutations)
      return nil if total.zero?

      (killed.to_f / total).round(4)
    end

    private

    attr_reader :agent_run
  end
end
