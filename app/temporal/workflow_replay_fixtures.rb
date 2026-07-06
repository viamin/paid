# frozen_string_literal: true

require "temporalio/activity/definition"

# Stub inputs and activity return values used to generate the checked-in
# Temporal replay-history fixtures (see
# `spec/fixtures/temporal/replay_histories/` and
# `script/temporal/export_replay_histories.rb`).
#
# These stubs produce SYNTHETIC histories, not staging captures: the
# export script drives each workflow through a time-skipping test
# environment using the fixed return values below. The resulting
# fixtures are a valid WorkflowReplayer input for the non-determinism
# guard, but they only cover the happy-path branches these stubs
# exercise. Branching driven by real activity results, error/timeout
# paths, or live poller iterations is NOT represented here.
module WorkflowReplayFixtures
  TASKS = [
    { index: 0, title: "Add migration", description: "Create users table", dependencies: [], parallel_group: 0 },
    { index: 1, title: "Add model", description: "Create User model", dependencies: [ 0 ], parallel_group: 1 }
  ].freeze

  CREATED_ISSUES = [
    { issue_id: 101, index: 0 },
    { issue_id: 102, index: 1 }
  ].freeze

  PROMPT_MUTATIONS = [
    {
      template: "improved {{title}}",
      strategy: "refinement",
      reasoning: "better structure",
      expected_improvement: "clarity"
    }
  ].freeze

  STRATEGY_MUTATION = {
    configuration: OrchestrationStrategies::Defaults.review_settings.deep_dup,
    strategy: "risk_reduction",
    reasoning: "Safer timeout",
    expected_improvement: "Fewer loops",
    diff: [ { path: "/methods/paid_agent/termination/timeout_minutes", from: 30, to: 20 } ],
    provenance: { source_version: 2 }
  }.freeze

  Scenario = Data.define(:workflow_class, :input)

  class StubActivityState
    def initialize
      @agent_run_id = 40
      @pull_request_number = 90
      @fetch_issues_calls = 0
    end

    def activity_definitions
      handlers.map do |name, handler|
        Temporalio::Activity::Definition::Info.new(name: activity_name_for(name)) do |*args|
          handler.call(*args)
        end
      end
    end

    private

    def activity_name_for(name)
      "Activities::#{name}".constantize._activity_definition_details.fetch(:activity_name)
    end

    def input_value(input, key)
      input[key] || input[key.to_s]
    end

    def handlers
      @handlers ||= {
        "AnalyzeKnowledgeGapsActivity" => ->(input) do
          {
            project_id: input_value(input, :project_id),
            recommendations: [
              {
                recommendation_type: "add_collector",
                collector_type: "database_schema",
                priority: "high",
                description: "Collects DB schemas"
              }
            ]
          }
        end,
        "CaptureScreenshotsActivity" => ->(_input) { { status: "captured", screenshot_count: 1 } },
        "CheckKnowledgeStalenessActivity" => ->(_input) { {} },
        "CheckProjectRunCapacityActivity" => ->(_input) do
          if input_value(_input, :project_id) == 999
            {
              has_capacity: false,
              available_slots: 0,
              project_active_count: 3,
              max_parallel_per_project: 3,
              user_active_count: 3,
              max_concurrent_runs: 10,
              pr_aggregation_enabled: false
            }
          else
            {
              has_capacity: true,
              available_slots: 2,
              project_active_count: 0,
              max_parallel_per_project: 5,
              user_active_count: 0,
              max_concurrent_runs: 10,
              pr_aggregation_enabled: false
            }
          end
        end,
        "CheckProxyHealthActivity" => ->(_input) { {} },
        "CheckQualityGateActivity" => ->(_input) { { allowed: true } },
        "CheckRateLimitActivity" => ->(_input) { { rate_limit_remaining: 500, rate_limit_low: false } },
        "CleanupContainerActivity" => ->(_input) { {} },
        "CleanupMcpServersActivity" => ->(_input) { {} },
        "CleanupServicesActivity" => ->(_input) { {} },
        "CleanupWorktreeActivity" => ->(_input) { {} },
        "CloneRepoActivity" => ->(_input) { {} },
        "CompleteReviewGoalActivity" => ->(input) { { agent_run_id: input_value(input, :agent_run_id), success: true } },
        "DraftDecisionRecordActivity" => ->(_input) { {} },
        "CreateAgentRunActivity" => lambda { |input|
          @agent_run_id += 1
          {
            agent_run_id: @agent_run_id,
            runner_attempt_count: 1,
            agent_timeout_seconds: 300,
            issue_goal_timeout_seconds: 60,
            focus: input_value(input, :focus) || "general"
          }
        },
        "CreateEvolutionAbTestActivity" => ->(_input) { { ab_test_id: 42, status: :created, generation: 1 } },
        "CreateEvolutionStrategyExperimentActivity" => ->(_input) { { strategy_experiment_id: 202, status: :created } },
        "CreateEvolutionVariantsActivity" => ->(_input) { { variant_version_ids: [ 100, 101 ], variant_count: 2 } },
        "CreatePullRequestActivity" => lambda { |_input|
          @pull_request_number += 1
          {
            pull_request_url: "https://github.com/example/repo/pull/#{@pull_request_number}",
            pull_request_number: @pull_request_number
          }
        },
        "CreateSubIssuesActivity" => ->(_input) { { created_issues: CREATED_ISSUES } },
        "DecomposeFeatureActivity" => ->(input) do
          {
            tasks:
              if input_value(input, :workflow_name) == "Workflows::FeatureOrchestrationWorkflow"
                [ TASKS.first ]
              else
                TASKS
              end,
            prompt_source: "policy_service",
            policy_metadata: {
              policy_source: "coordination_policy",
              policy_key: "feature_decomposition",
              coordination_policy_id: 12,
              coordination_policy_version_id: 34,
              coordination_policy_version: 5
            }
          }
        end,
        "DetectConflictsActivity" => ->(input) do
          {
            project_id: input_value(input, :project_id),
            has_conflicts: false,
            conflicting_pairs: [],
            files_by_run: [],
            total_runs_checked: Array(input_value(input, :agent_run_ids)).size,
            detection_failed: false,
            failed_run_ids: [],
            requires_manual_review: false,
            resolution: nil,
            error: nil
          }
        end,
        "DetectLabelsActivity" => ->(_input) do
          {
            decisions: [ { type: "queue_review_run", issue_id: 10, source_pull_request_number: 42, focus: "general" } ],
            action: "none",
            issue_id: 10,
            project_id: 1
          }
        end,
        "EnqueueJanitorActivity" => ->(input) { { agent_run_id: input[:agent_run_id] } },
        "EvaluateAutoReleaseActivity" => ->(_input) { {} },
        "EvaluateDependabotAutoMergeActivity" => ->(_input) { {} },
        "EvaluateIssuesActivity" => ->(_input) do
          {
            results: [ { decisions: [ { type: "queue_review_run", issue_id: 10, source_pull_request_number: 42, focus: "general" } ] } ]
          }
        end,
        "EvaluateNotificationRulesActivity" => ->(_input) { {} },
        "FetchIssuesActivity" => lambda { |input|
          @fetch_issues_calls += 1
          if @fetch_issues_calls == 1
            { issues: [ { id: 10 } ], enhance_issue_rechecks: [], project_id: input_value(input, :project_id) }
          else
            { issues: [], enhance_issue_rechecks: [], project_id: input_value(input, :project_id), project_missing: true }
          end
        },
        "FetchPlanningContextActivity" => ->(_input) { { context: { issue_title: "Feature", knowledge_snippets: [] } } },
        "GenerateCoordinationPolicyCandidatesActivity" => ->(_input) { { mutations: [ { policy: { "parallel_execution" => { "max_batch_size" => 2 } } } ] } },
        "GenerateMutationsActivity" => ->(_input) { { mutations: PROMPT_MUTATIONS } },
        "GenerateStrategyMutationsActivity" => ->(_input) { { mutations: [ STRATEGY_MUTATION ] } },
        "GetPollIntervalActivity" => ->(_input) { { poll_interval_seconds: 60 } },
        "LoadFeatureFlagsActivity" => ->(_input) { { flags: {}, project_missing: false } },
        "LogDecompositionDecisionActivity" => ->(_input) { { decomposition_decision_id: 1 } },
        "MarkAgentRunCompleteActivity" => ->(_input) { {} },
        "PersistCoordinationPolicyCandidatesActivity" => ->(_input) { { candidate_ids: [ 301 ], candidate_count: 1 } },
        "PersistStrategyCandidatesActivity" => ->(_input) { { candidate_ids: [ 101 ], candidate_count: 1 } },
        "PrepareCoordinationPolicyEvolutionInputsActivity" => ->(input) do
          {
            account_id: input_value(input, :account_id),
            policy_type: CoordinationPolicyEvolution::PrepareInputs::POLICY_TYPE,
            policy: { id: 5, configuration: OrchestrationStrategies::Defaults.feature_orchestration },
            performance: { decision_count: 12, classified_decision_count: 12, min_decisions: 10 },
            prior_versions: [],
            sample_successes: [],
            sample_failures: []
          }
        end,
        "PrepareStrategyEvolutionInputsActivity" => ->(input) do
          {
            account_id: input_value(input, :account_id),
            strategy_type: input_value(input, :strategy_type),
            strategy: {
              id: 3,
              strategy_type: "review_settings",
              name: "Review Settings",
              version: 2,
              configuration: OrchestrationStrategies::Defaults.review_settings
            },
            prior_versions: [],
            performance: { decision_count: 12, min_decisions: 10 },
            sample_successes: [],
            sample_failures: []
          }
        end,
        "ProvisionContainerActivity" => ->(_input) { {} },
        "ProvisionMcpServersActivity" => ->(_input) { {} },
        "ProvisionServicesActivity" => ->(_input) { {} },
        "PushBranchActivity" => ->(_input) { {} },
        "QueueAgentRunActivity" => ->(_input) { { queued: true } },
        "RecordCoordinationExperimentOutcomeActivity" => ->(_input) { { assignment_id: 77, outcome_status: "recorded" } },
        "RecordKnowledgeRecommendationsActivity" => ->(input) do
          { project_id: input_value(input, :project_id), created_count: 1, dismissed_count: 0 }
        end,
        "RecordPollHeartbeatActivity" => ->(_input) { { recorded: true } },
        "RecordScalingExperimentResultActivity" => ->(_input) { { assignment_id: 88, outcome_status: "recorded" } },
        "RecordScalingObservationActivity" => ->(_input) { { scaling_observation_id: 1 } },
        "RequestReviewActivity" => ->(_input) { {} },
        "ResolveCoordinationExperimentActivity" => ->(_input) do
          { assignment_id: 77, coordination_policy: OrchestrationStrategies::Defaults.feature_orchestration }
        end,
        "ResolveScalingExperimentActivity" => ->(_input) do
          {
            learned_allocation: {
              agent_count: 2,
              max_iterations: 4,
              parallelism_level: 2,
              source: :observations,
              reason: "best observed agent_count=2"
            },
            assignments: [
              {
                assignment_id: 88,
                dimension: "agent_count",
                execution_plan: {
                  "dimension" => "agent_count",
                  "requested_agent_count" => 2,
                  "max_batch_size" => 2
                }
              },
              {
                assignment_id: 99,
                dimension: "iteration_count",
                execution_plan: {
                  "dimension" => "iteration_count",
                  "requested_iteration_count" => 3,
                  "application_mode" => "task_prompt_budget",
                  "prompt_suffix" => "Iteration budget: aim to complete this task within 3 agent iterations."
                }
              }
            ]
          }
        end,
        "RunAgentActivity" => ->(_input) { { success: true, has_changes: true } },
        "ScanSecurityAlertsActivity" => ->(_input) { {} },
        "SampleEnhanceRunsActivity" => ->(input) do
          {
            runs: [ { agent_run_id: 10, issue_title: "Add auth", questions_asked: [ "How does auth work?" ] } ],
            artifact_usage: { "route" => { total_runs: 50, success_rate: 80.0 } },
            project_id: input_value(input, :project_id)
          }
        end,
        "SampleRunsActivity" => ->(input) do
          {
            prompt_id: input_value(input, :prompt_id),
            evolution_candidates: [ { prompt_version_id: 10, avg_score: 0.55, run_count: 10, reasons: [ "low quality" ] } ],
            prompt_stats: { 10 => { avg_score: 0.55, run_count: 10 } },
            sample_outputs: { successes: [], failures: [ "low score" ] },
            quality_metrics: [ { composite_score: 0.55 } ],
            total_samples: 50
          }
        end,
        "ScanPaidPrsActivity" => ->(_input) { { automation_results: [] } },
        "UpdateIssueWithPrActivity" => ->(_input) { {} },
        "UpdatePlanningLabelsActivity" => ->(_input) { { success: true } }
      }
    end
  end

  SCENARIOS = {
    "Workflows::AgentExecutionWorkflow" => Scenario.new(
      workflow_class: Workflows::AgentExecutionWorkflow,
      input: { project_id: 1, issue_id: 101, goal: "create_pr" }
    ),
    "Workflows::CoordinationPolicyEvolutionWorkflow" => Scenario.new(
      workflow_class: Workflows::CoordinationPolicyEvolutionWorkflow,
      input: { account_id: 9 }
    ),
    "Workflows::FeatureOrchestrationWorkflow" => Scenario.new(
      workflow_class: Workflows::FeatureOrchestrationWorkflow,
      input: { project_id: 1, issue_id: 2000 }
    ),
    "Workflows::GitHubPollWorkflow" => Scenario.new(
      workflow_class: Workflows::GitHubPollWorkflow,
      input: { project_id: 1 }
    ),
    "Workflows::KnowledgeEvolutionWorkflow" => Scenario.new(
      workflow_class: Workflows::KnowledgeEvolutionWorkflow,
      input: { project_id: 1 }
    ),
    "Workflows::ParallelAgentExecutionWorkflow" => Scenario.new(
      workflow_class: Workflows::ParallelAgentExecutionWorkflow,
      input: {
        project_id: 999,
        sub_tasks: [
          { issue_id: 201, task_index: 0, dependencies: [] },
          { issue_id: 202, task_index: 1, dependencies: [ 0 ] }
        ]
      }
    ),
    "Workflows::PlanningWorkflow" => Scenario.new(
      workflow_class: Workflows::PlanningWorkflow,
      input: { project_id: 1, issue_id: 2 }
    ),
    "Workflows::PromptEvolutionWorkflow" => Scenario.new(
      workflow_class: Workflows::PromptEvolutionWorkflow,
      input: { prompt_id: 1, project_id: 2 }
    ),
    "Workflows::StrategyEvolutionWorkflow" => Scenario.new(
      workflow_class: Workflows::StrategyEvolutionWorkflow,
      input: { account_id: 9, strategy_type: "review_settings" }
    )
  }.freeze

  module_function

  def workflow_classes
    SCENARIOS.values.map(&:workflow_class).sort_by(&:name)
  end

  def scenario_for(workflow_class)
    SCENARIOS.fetch(workflow_class.name)
  end

  def activity_definitions
    StubActivityState.new.activity_definitions
  end
end
