# frozen_string_literal: true

module Orchestration
  module DecompositionDecisions
    class Log
      def self.call(...)
        new(...).call
      end

      def initialize(project_id:, issue_id:, decision_key:, workflow_name:, workflow_id:, decision_type:, outcome:,
        input_context: {}, plan_data: {}, error_details: {}, metadata: {})
        @project_id = project_id
        @issue_id = issue_id
        @decision_key = decision_key
        @workflow_name = workflow_name
        @workflow_id = workflow_id
        @decision_type = decision_type
        @outcome = outcome
        @input_context = normalize_hash(input_context)
        @plan_data = normalize_hash(plan_data)
        @error_details = normalize_hash(error_details)
        @metadata = normalize_hash(metadata)
      end

      def call
        existing = DecompositionDecision.find_by(decision_key: decision_key)
        return existing.tap { ensure_orchestration_decision! } if existing

        decision = DecompositionDecision.create!(
          project_id: project_id,
          issue_id: issue_id,
          decision_key: decision_key,
          workflow_name: workflow_name,
          workflow_id: workflow_id,
          decision_type: decision_type,
          outcome: outcome,
          input_context: enriched_input_context,
          plan_data: plan_data,
          hints: derived_hints,
          error_details: error_details,
          metadata: metadata
        )
        ensure_orchestration_decision!
        decision
      rescue ActiveRecord::RecordNotUnique
        DecompositionDecision.find_by!(decision_key: decision_key).tap { ensure_orchestration_decision! }
      end

      private

      attr_reader :project_id, :issue_id, :decision_key, :workflow_name, :workflow_id,
        :decision_type, :outcome, :input_context, :plan_data, :error_details, :metadata

      def issue
        @issue ||= Issue.find(issue_id)
      end

      def enriched_input_context
        input_context.merge(
          "issue" => {
            "id" => issue.id,
            "github_number" => issue.github_number,
            "github_url" => issue.github_url,
            "title" => issue.title,
            "labels" => issue.labels
          }
        )
      end

      def derived_hints
        tasks = Array(plan_data["tasks"])
        created_issues = Array(plan_data["created_issues"])
        dependency_map = tasks.to_h do |task|
          [ task["index"], Array(task["dependencies"]) ]
        end
        parallel_groups = tasks.group_by { |task| task["parallel_group"] }

        {
          "task_count" => tasks.size,
          "created_issue_count" => created_issues.size,
          "created_issue_numbers" => created_issues.filter_map { |issue_data| issue_data["github_number"] },
          "dependency_edges" => dependency_map.values.sum(&:size),
          "tasks_with_dependencies" => dependency_map.count { |_task_index, dependencies| dependencies.any? },
          "dependency_map" => dependency_map,
          "parallel_groups" => parallel_groups.transform_values { |group| group.map { |task| task["index"] } },
          "parallelizable_groups" => parallel_groups.select { |_group, tasks_in_group| tasks_in_group.size > 1 }
            .transform_values { |group| group.map { |task| task["index"] } }
        }
      end

      def normalize_hash(value)
        case value
        when Hash
          value.deep_stringify_keys
        else
          {}
        end
      end

      def ensure_orchestration_decision!
        existing = OrchestrationDecision.find_by(
          [
            <<~SQL.squish,
              project_id = ?
              AND decision_type = ?
              AND actor = ?
              AND context ->> 'decision_key' = ?
            SQL
            project_id,
            decision_type,
            workflow_name,
            decision_key
          ]
        )
        return existing if existing

        OrchestrationDecision.create!(
          project_id: project_id,
          decision_type: decision_type,
          actor: workflow_name,
          context: {
            decision_key: decision_key,
            workflow_id: workflow_id,
            workflow_name: workflow_name,
            issue_id: issue_id,
            decision_status: error_details.present? ? "failed" : "applied"
          },
          inputs: enriched_input_context,
          outputs: {
            outcome: outcome,
            plan_data: plan_data,
            hints: derived_hints,
            error_details: error_details,
            metadata: metadata
          },
          outcome_references: []
        )
      end
    end
  end
end
