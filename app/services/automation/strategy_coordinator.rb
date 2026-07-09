# frozen_string_literal: true

module Automation
  class StrategyCoordinator
    attr_reader :project, :selector

    def initialize(project:, selector: Automation::Strategies::Select)
      @project = project
      @selector = selector
    end

    def evaluate(context:, strategy_types:)
      decisions = Array(strategy_types).flat_map do |strategy_type|
        selector.call(strategy_type: strategy_type, project: project)
          .evaluate(context)
          .decisions
      end

      Result.new(decisions: resolve(decisions))
    end

    def evaluate_pull_request(record:, metadata:, strategy_types: %i[auto_continue])
      context = Context.build(record: record, project: project, metadata: metadata)
      evaluate(context:, strategy_types:)
    end

    private

    def resolve(decisions)
      unique_decisions = decisions.uniq
      return [ Decision.noop ] if unique_decisions.empty?

      merge_decision = unique_decisions.find { |decision| decision.type == "merge" }
      return [ merge_decision ] if merge_decision

      unique_decisions
    end
  end
end
