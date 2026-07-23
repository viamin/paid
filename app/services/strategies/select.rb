# frozen_string_literal: true

module Strategies
  # Public API for context-aware strategy selection from database-backed
  # Strategy records. Wraps OrchestrationStrategySelector with enriched
  # context (task_type injection) and a structured Result that includes
  # fallback semantics.
  #
  # Called at active orchestration decision points so that learned strategy
  # configuration takes effect at runtime:
  #
  # - issue_execution — Activities::CreateAgentRunActivity, on every new run
  #   and resumed-run path, to select and log a strategy governing the run.
  # - auto_continue / auto_merge — Automation::StrategyCoordinator, alongside
  #   the in-memory registry path, to select against PR lifecycle runtime
  #   context and log DB-backed strategy selection for each evaluation.
  # - decomposition_strategy / planning_outcome / parallelization_outcome —
  #   feature-orchestration
  #   workflows, via Orchestration::DecompositionDecisions::Log.
  #
  # Always returns a Result (never raises). When no learned strategy matches
  # the context, the result is a fallback with empty content so callers can
  # proceed with baseline behaviour. Decision logging happens in the caller.
  class Select
    Result = Data.define(:strategy, :strategy_version, :scope, :fallback, :matched_rule_count) do
      def content
        strategy_version&.content || {}
      end

      def found?
        !fallback
      end

      def to_s
        if found?
          "#{strategy.name} (#{scope}, v#{strategy_version.version})"
        else
          "fallback"
        end
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(decision_type:, context: {}, project: nil, account: nil, task_type: nil)
      @decision_type = decision_type.to_s
      @context = context
      @project = project
      @account = account
      @task_type = task_type
    end

    def call
      selector_result = OrchestrationStrategySelector.call(
        decision_type: decision_type,
        context: enriched_context,
        project: project,
        account: account
      )

      if selector_result
        build_matched_result(selector_result)
      else
        build_fallback_result
      end
    end

    private

    attr_reader :decision_type, :context, :project, :account, :task_type

    def enriched_context
      base = normalize_hash(context)
      base["task_type"] ||= task_type.to_s if task_type.present?
      base
    end

    def build_matched_result(selector_result)
      Result.new(
        strategy: selector_result.strategy,
        strategy_version: selector_result.strategy_version,
        scope: selector_result.scope,
        fallback: false,
        matched_rule_count: selector_result.matched_rule_count
      )
    end

    def build_fallback_result
      Result.new(
        strategy: nil,
        strategy_version: nil,
        scope: :fallback,
        fallback: true,
        matched_rule_count: 0
      )
    end

    def normalize_hash(value)
      return {} unless value.is_a?(Hash)

      value.deep_stringify_keys
    end
  end
end
