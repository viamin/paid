# frozen_string_literal: true

module Strategies
  module BaselineOrchestration
    module_function

    DECOMPOSITION_STRATEGY_SLUG = "orchestration.decomposition_strategy"
    PLANNING_OUTCOME_SLUG = "orchestration.planning_outcome"
    PARALLELIZATION_OUTCOME_SLUG = "orchestration.parallelization_outcome"

    def definitions
      [
        {
          slug: DECOMPOSITION_STRATEGY_SLUG,
          name: "Baseline Decomposition Strategy",
          description: "Current hardcoded decomposition workflow behavior extracted into a versioned strategy record.",
          decision_type: "decomposition_strategy",
          selection_rules: { "scope" => "global", "workflow_step" => "decompose_feature" },
          content: decomposition_strategy
        },
        {
          slug: PLANNING_OUTCOME_SLUG,
          name: "Baseline Planning Outcome Strategy",
          description: "Current hardcoded planning outcome workflow behavior extracted into a versioned strategy record.",
          decision_type: "planning_outcome",
          selection_rules: { "scope" => "global", "workflow" => "planning" },
          content: planning_outcome
        },
        {
          slug: PARALLELIZATION_OUTCOME_SLUG,
          name: "Baseline Parallelization Outcome Strategy",
          description: "Current hardcoded parallelization workflow behavior extracted into a versioned strategy record.",
          decision_type: "parallelization_outcome",
          selection_rules: { "scope" => "global", "workflow" => "feature_orchestration" },
          content: parallelization_outcome
        }
      ].freeze
    end

    def slug_for_decision_type(decision_type)
      case decision_type.to_s
      when "decomposition_strategy" then DECOMPOSITION_STRATEGY_SLUG
      when "planning_outcome" then PLANNING_OUTCOME_SLUG
      when "parallelization_outcome" then PARALLELIZATION_OUTCOME_SLUG
      end
    end

    def decomposition_strategy
      {
        "policy_service" => {
          "strategy_type" => Coordination::DecompositionService::STRATEGY_TYPE,
          "default_policy" => Coordination::DecompositionService::DEFAULT_POLICY.deep_dup,
          "prompt_source" => Activities::DecomposeFeatureActivity::POLICY_PROMPT_SOURCE,
          "uses_policy_result_when" => %w[decomposed policy_skipped_non_default_source]
        },
        "llm_fallback" => {
          "prompt_slug" => Activities::DecomposeFeatureActivity::PROMPT_SLUG,
          "model" => Activities::DecomposeFeatureActivity::DEFAULT_MODEL,
          "timeout_seconds" => Activities::DecomposeFeatureActivity::TIMEOUT,
          "max_tasks" => Activities::DecomposeFeatureActivity::MAX_TASKS
        },
        "outcomes" => %w[
          policy_decomposed
          policy_skipped
          llm_generated_plan
          llm_fallback_after_policy_failure
          llm_decomposition_failed
          llm_fallback_failed_after_policy_failure
        ]
      }
    end

    def planning_outcome
      outcomes = Workflows::PlanningWorkflow.outcome_mappings

      {
        "steps" => %w[
          fetch_planning_context
          decompose_feature
          create_sub_issues
          update_planning_labels
        ],
        "success_outcomes" => outcomes[:success],
        "failure_outcomes" => outcomes[:failure]
      }
    end

    def parallelization_outcome
      outcomes = Workflows::FeatureOrchestrationWorkflow.parallelization_outcome_mappings

      {
        "default_timeout_seconds" => Workflows::FeatureOrchestrationWorkflow::DEFAULT_TIMEOUT_SECONDS,
        "minimum_parallel_task_count" => 2,
        "child_workflow" => "Workflows::ParallelAgentExecutionWorkflow",
        "success_outcomes" => outcomes[:success],
        "failure_outcomes" => outcomes[:failure]
      }
    end
  end
end
