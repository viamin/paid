# frozen_string_literal: true

module Automation
  class StrategyCoordinator
    PullRequestScanOutcome = ::Data.define(:result, :metadata, :legacy_trigger) do
      def noop?
        result.decisions.all? { |decision| decision.type == "noop" }
      end

      def to_h
        metadata.merge(result.to_h)
      end
    end

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

    def evaluate_pull_request_scan(record:, scan:, lifecycle:, strategy_types: %i[auto_continue])
      metadata = {}
      metadata[:scan] = scan if scan
      metadata[:lifecycle] = lifecycle if lifecycle

      result = evaluate_pull_request(record:, metadata:, strategy_types:)

      PullRequestScanOutcome.new(
        result: result,
        metadata: pull_request_scan_metadata(record, scan, lifecycle),
        legacy_trigger: legacy_trigger_for(record, scan, lifecycle, result)
      )
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

    def pull_request_scan_metadata(record, scan, lifecycle)
      metadata = {
        issue_id: record.id,
        pr_number: record.github_number,
        phase: lifecycle&.dig(:phase),
        draft: lifecycle&.dig(:draft),
        lifecycle_phase: lifecycle&.dig(:phase),
        lifecycle_draft: lifecycle&.dig(:draft),
        owner_reviewer_login: lifecycle&.dig(:owner_reviewer_login)
      }
      metadata.merge!(scan.except(:decisions)) if scan.is_a?(Hash)
      metadata
    end

    def legacy_trigger_for(record, scan, lifecycle, result)
      decisions = result.decisions
      escalate = decisions.find { |decision| decision.type == "escalate" }
      return {
        pr_number: record.github_number,
        phase: lifecycle&.dig(:phase),
        draft: lifecycle&.dig(:draft),
        owner_reviewer_login: escalate.payload[:owner_reviewer_login],
        triggers: [ {
          type: "escalate_to_owner",
          details: escalate.payload[:reason],
          reason_key: escalate.payload[:reason_key]
        } ]
      } if escalate

      return scan if scan.is_a?(Hash)

      mark_ready = decisions.find { |decision| decision.type == "mark_ready" }
      return {
        pr_number: record.github_number,
        phase: lifecycle&.dig(:phase),
        draft: lifecycle&.dig(:draft),
        owner_reviewer_login: mark_ready.payload[:owner_reviewer_login],
        triggers: [ { type: "ready_for_owner" } ]
      } if mark_ready

      merge = decisions.find { |decision| decision.type == "merge" }
      return {
        pr_number: record.github_number,
        phase: lifecycle&.dig(:phase),
        draft: lifecycle&.dig(:draft),
        triggers: [ { type: "owner_approved" } ]
      } if merge

      nil
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
