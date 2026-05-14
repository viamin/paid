# frozen_string_literal: true

module OrchestrationStrategies
  # Central registry of hardcoded orchestration defaults extracted from
  # their original locations across the codebase. Each method returns the
  # configuration hash that would be persisted in an OrchestrationStrategy
  # record, keeping runtime semantics identical.
  module Defaults
    module_function

    def configuration_for(strategy_type)
      case strategy_type.to_s
      when "review_settings"      then review_settings
      when "quality_gate"         then quality_gate
      when "execution_timeouts"   then execution_timeouts
      when "retry_policies"       then retry_policies
      when "agent_settings"       then agent_settings
      when "feature_orchestration" then feature_orchestration
      when "provider_resolution"  then provider_resolution
      end
    end

    # Extracted from Project::DEFAULT_REVIEW_SETTINGS (app/models/project.rb:32-86)
    def review_settings
      {
        "enabled" => false,
        "wait_for_reviews" => true,
        "address_all_bot_reviews" => false,
        "methods" => {
          "copilot" => {
            "enabled" => false,
            "termination" => {
              "max_review_rounds" => 15,
              "stop_when_no_comments" => true,
              "quality_threshold" => nil,
              "timeout_minutes" => nil
            }
          },
          "paid_agent" => {
            "enabled" => false,
            "termination" => {
              "max_review_rounds" => 15,
              "max_review_goal_retries" => 3,
              "stop_when_no_comments" => true,
              "quality_threshold" => nil,
              "timeout_minutes" => 30
            }
          },
          "codex" => {
            "enabled" => false,
            "termination" => {
              "max_review_rounds" => 15,
              "stop_when_no_comments" => true,
              "quality_threshold" => nil,
              "timeout_minutes" => 60
            }
          },
          "ci_action" => {
            "enabled" => false,
            "action_name" => nil,
            "termination" => {
              "max_review_rounds" => nil,
              "stop_when_no_comments" => true,
              "quality_threshold" => nil,
              "timeout_minutes" => nil
            }
          },
          "manual" => {
            "enabled" => false,
            "reviewer_login" => nil,
            "termination" => {
              "max_review_rounds" => nil,
              "stop_when_no_comments" => false,
              "quality_threshold" => nil,
              "timeout_minutes" => 1440
            }
          }
        }
      }
    end

    # Extracted from Project::DEFAULT_QUALITY_GATE_SETTINGS (app/models/project.rb:88-94)
    def quality_gate
      {
        "enabled" => false,
        "composite_score_threshold" => 0.5,
        "min_recent_runs" => 3,
        "lookback_window_hours" => 24,
        "metric_thresholds" => {}
      }
    end

    # Extracted from:
    #   - AGENT_TIMEOUT_DEFAULT (config/initializers/agent_harness.rb:71)
    #   - Activities::RunAgentActivity (app/temporal/activities/run_agent_activity.rb:77-83)
    #   - Workflows::FeatureOrchestrationWorkflow::DEFAULT_TIMEOUT_SECONDS (line 24)
    def execution_timeouts
      {
        "agent_timeout_default_seconds" => 3600,
        "issue_goal_timeout_seconds" => 600,
        "issue_goal_idle_timeout_seconds" => 120,
        "review_goal_idle_timeout_seconds" => 300,
        "create_pr_idle_timeout_seconds" => 300,
        "preflight_timeout_seconds" => 10,
        "feature_orchestration_timeout_seconds" => 7200
      }
    end

    # Extracted from Workflows::AgentExecutionWorkflow (app/temporal/workflows/agent_execution_workflow.rb:18-49)
    def retry_policies
      {
        "run_agent" => {
          "max_attempts" => 2,
          "initial_interval_seconds" => 5,
          "max_interval_seconds" => 5,
          "backoff_coefficient" => 2.0
        },
        "cleanup" => {
          "max_attempts" => 5,
          "initial_interval_seconds" => 2,
          "max_interval_seconds" => 15,
          "backoff_coefficient" => 2.0
        },
        "change_detection" => {
          "max_attempts" => 3,
          "retry_backoff_seconds" => 0.25
        }
      }
    end

    # Extracted from TenantSetting::DEFAULT_AGENT_SETTINGS (app/models/tenant_setting.rb:28-31)
    # and TenantSetting::DEFAULT_GUARDRAILS (app/models/tenant_setting.rb:18-22)
    def agent_settings
      {
        "default_goal" => "create_pr",
        "auto_continue" => true,
        "guardrails" => {
          "max_concurrent_runs" => 10,
          "max_tokens_per_run" => 10_000_000,
          "max_monthly_cost_cents" => nil
        }
      }
    end

    # Extracted from Workflows::FeatureOrchestrationWorkflow (app/temporal/workflows/feature_orchestration_workflow.rb)
    # and Workflows::AgentExecutionWorkflow known failure types (lines 55-72)
    def feature_orchestration
      planning_mappings = Workflows::PlanningWorkflow.outcome_mappings
      parallelization_mappings = Workflows::FeatureOrchestrationWorkflow.parallelization_outcome_mappings

      {
        "default_timeout_seconds" => 7200,
        "escalation" => {
          "human_value_threshold" => 0.65,
          "explicit_triggers" => %w[
            operational_failure_breaker
            review_goal_retry_limit_requires_escalation
            draft_review_limit_reached
            consecutive_draft_failures_breaker
          ],
          "auto_resolve_trigger_types" => %w[
            owner_approved
            ready_for_owner
          ],
          "weights" => {
            "operational_failure_breaker" => 0.45,
            "review_goal_retry_pressure" => 0.3,
            "draft_review_pressure" => 0.2,
            "followup_pressure" => 0.15,
            "blocking_triggers" => 0.15,
            "owner_reviewer_present" => 0.1,
            "escalated_phase" => 0.1
          },
          "interruption_cost" => {
            "base" => 0.3,
            "missing_owner_reviewer" => 0.25,
            "draft_phase_discount" => 0.05,
            "escalated_phase_discount" => 0.1
          }
        },
        "recovery" => {
          "actions" => Coordination::FailureRecoveryPolicy::DEFAULT_ACTIONS.deep_dup,
          "default_action" => Coordination::FailureRecoveryPolicy::DEFAULT_ACTION
        },
        "decomposition" => {
          "enabled" => true,
          "max_tasks" => 20,
          "min_components_to_decompose" => 2,
          "layer_order" => %w[model service controller view]
        },
        "parallel_execution" => {
          "max_batch_size" => nil,
          "cancel_remaining_on_failure" => false
        },
        "planning_phases" => %w[
          fetch_planning_context
          decompose_feature
          create_sub_issues
          update_planning_labels
        ],
        "planning_outcomes" => planning_mappings[:success] + planning_mappings[:failure].values,
        "parallelization_outcomes" => parallelization_mappings[:success] + parallelization_mappings[:failure].values,
        "known_failure_types" => %w[
          AllProvidersExhausted
          AgentExecutionFailed
          IssueDraftInvalid
          McpProvisioningFailed
          MissingPrompt
          MissingUser
          ContainerNotProvisioned
          ProxyUnavailable
          RateLimit
        ],
        "known_failure_classes" => %w[
          GithubClient::RateLimitError
          GithubClient::AuthenticationError
        ]
      }
    end

    # Extracted from:
    #   - Automation::Configuration::ReviewMethod::NAMES (app/services/automation/configuration/review_method.rb:16)
    #   - Automation::Configuration::AutoReview::BOT_REQUEST_PRIORITY (line 23)
    #   - Automation::Configuration::AutoReview::BOT_REVIEWER_LOGINS (lines 29-32)
    #   - AgentRun::GOALS (app/models/agent_run.rb:16)
    #   - AgentRun::AGENT_TYPES (app/models/agent_run.rb:14)
    def provider_resolution
      {
        "review_method_names" => %w[copilot paid_agent codex ci_action manual],
        "bot_request_priority" => %w[copilot codex],
        "bot_reviewer_logins" => {
          "copilot" => "copilot",
          "codex" => "chatgpt-codex-connector"
        },
        "agent_types" => AgentRun::AGENT_TYPES,
        "goals" => %w[create_pr create_issue review enhance_issue analyze_issue],
        "non_container_goals" => %w[enhance_issue analyze_issue]
      }
    end

    def all
      OrchestrationStrategy::STRATEGY_TYPES.index_with do |type|
        configuration_for(type)
      end
    end
  end
end
