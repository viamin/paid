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
        log_db_strategy_for(strategy_type.to_s, context)
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

    def log_db_strategy_for(decision_type, context)
      selection_context = selection_context_for(context)
      result = ::Strategies::Select.call(
        decision_type: decision_type,
        context: selection_context,
        project: project
      )

      OrchestrationDecision.create!(
        project: project,
        decision_type: decision_type,
        actor: self.class.name,
        strategy_version: result.strategy_version,
        context: {
          "decision_status" => result.found? ? "applied" : "noop",
          "scope" => result.scope.to_s,
          "strategy" => result.to_s,
          "matched_rule_count" => result.matched_rule_count
        },
        inputs: selection_context,
        outputs: result.content,
        outcome_references: []
      )
    rescue => e
      Rails.logger.warn(
        message: "strategy_coordinator.db_strategy_selection_failed",
        project_id: project.id,
        decision_type: decision_type,
        error_class: e.class.name,
        error: e.message
      )
    end

    def selection_context_for(context)
      metadata = normalize_hash(context.metadata)
      scan = normalize_hash(metadata["scan"])
      lifecycle = normalize_hash(metadata["lifecycle"])
      record = context.record

      {
        "record_type" => record&.class&.name,
        "record_id" => record&.id,
        "github_number" => record&.github_number,
        "phase" => scan["phase"] || lifecycle["phase"],
        "draft" => lifecycle["draft"],
        "labels" => Array(record&.try(:labels)),
        "trigger_types" => Array(scan["triggers"]).filter_map { |trigger| trigger_type(trigger) },
        "metadata" => metadata
      }.compact
    end

    def trigger_type(trigger)
      return unless trigger.is_a?(Hash)

      trigger["type"] || trigger[:type]
    end

    def normalize_hash(value)
      return {} unless value.is_a?(Hash)

      value.deep_stringify_keys
    end

    def resolve(decisions)
      unique_decisions = decisions.uniq
      return [ Decision.noop ] if unique_decisions.empty?

      merge_decision = unique_decisions.find { |decision| decision.type == "merge" }
      return [ merge_decision ] if merge_decision

      unique_decisions
    end
  end
end
