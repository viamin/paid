# frozen_string_literal: true

module Workflows
  # Orchestrates the prompt evolution cycle for a single prompt:
  #
  # 1. Sample completed agent runs with quality metrics
  # 2. Evaluate quality and identify underperforming prompts
  # 3. Generate mutations (improved prompt variants) via LLM
  # 4. Persist variants as PromptVersion records
  # 5. Create an A/B test to compare variants against the control
  #
  # Triggered by PromptEvolutionJob on a weekly schedule per project,
  # or manually via Temporal client for a specific prompt.
  #
  # Input:
  #   prompt_id:       - ID of the prompt to evolve
  #   project_id:      - Optional project scope for sampling
  #   sample_size:     - Number of runs to sample (default: 50)
  #   sample_days:     - Lookback window in days (default: 14)
  #   mutation_count:  - Number of variants to generate (default: 3)
  #   strategies:      - Mutation strategies to apply (default: all)
  #   min_samples:     - Minimum samples per A/B test variant (default: 30)
  #   confidence:      - Statistical confidence threshold (default: 0.95)
  class PromptEvolutionWorkflow < BaseWorkflow
    # Explicit activity timeouts (BaseWorkflow default is 300s)
    AB_TEST_TIMEOUT = 30

    def execute(input)
      prompt_id = input[:prompt_id]
      project_id = input[:project_id]
      recovery_action_id = input[:recovery_action_id]

      Temporalio::Workflow.logger.info(
        "PromptEvolutionWorkflow started for prompt=#{prompt_id} project=#{project_id}"
      )

      # Step 1: Sample completed runs and evaluate quality
      sample_result = run_activity(
        Activities::SampleRunsActivity,
        {
          prompt_id: prompt_id,
          project_id: project_id,
          goal_type: input[:goal_type],
          sample_size: input.fetch(:sample_size, 50),
          sample_days: input.fetch(:sample_days, 14),
          failure_only: input.fetch(:failure_only, false),
          metric_type: input.fetch(:metric_type, "composite_score"),
          threshold: input.fetch(:threshold, PromptEvolution::SampleRuns::QUALITY_THRESHOLD),
          min_runs_for_evaluation: input.fetch(
            :min_runs_for_evaluation,
            PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION
          )
        },
        timeout: 60
      )

      candidates = sample_result[:evolution_candidates]

      unless candidates.present?
        Temporalio::Workflow.logger.info(
          "PromptEvolutionWorkflow: no evolution candidates for prompt=#{prompt_id}"
        )
        fail_recovery_action(recovery_action_id, :no_candidates)
        return {
          status: :no_candidates,
          prompt_id: prompt_id,
          prompt_stats: sample_result[:prompt_stats]
        }
      end

      # Step 2: Generate mutations via LLM
      mutation_result = run_activity(
        Activities::GenerateMutationsActivity,
        {
          prompt_id: prompt_id,
          quality_metrics: sample_result[:quality_metrics],
          sample_outputs: sample_result[:sample_outputs],
          mutation_count: input.fetch(:mutation_count, 3),
          strategies: input[:strategies]
        },
        timeout: LLM_ACTIVITY_TIMEOUT,
        heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT
      )

      mutations = mutation_result[:mutations]

      if mutations.blank?
        Temporalio::Workflow.logger.info(
          "PromptEvolutionWorkflow: no mutations generated for prompt=#{prompt_id}"
        )
        fail_recovery_action(recovery_action_id, :no_mutations)
        return {
          status: :no_mutations,
          prompt_id: prompt_id,
          candidates: candidates
        }
      end

      # Step 3: Persist variant PromptVersions
      variants_result = run_activity(
        Activities::CreateEvolutionVariantsActivity,
        {
          prompt_id: prompt_id,
          project_id: project_id,
          mutations: mutations
        },
        timeout: 30
      )

      variant_version_ids = variants_result[:variant_version_ids]

      if variant_version_ids.blank?
        fail_recovery_action(recovery_action_id, :no_variants_created)
        return {
          status: :no_variants_created,
          prompt_id: prompt_id
        }
      end

      # Step 4: Create A/B test for evolved variants vs control
      ab_test_result = run_activity(
        Activities::CreateEvolutionAbTestActivity,
        {
          prompt_id: prompt_id,
          variant_version_ids: variant_version_ids,
          min_samples_per_variant: input.fetch(:min_samples, 30),
          confidence_threshold: input.fetch(:confidence, 0.95),
          recovery_action_id: recovery_action_id
        },
        timeout: AB_TEST_TIMEOUT
      )

      {
        status: :evolution_started,
        prompt_id: prompt_id,
        ab_test_id: ab_test_result[:ab_test_id],
        variant_count: variant_version_ids.size,
        generation: ab_test_result[:generation]
      }

    rescue => e
      Temporalio::Workflow.logger.error(
        message: "PromptEvolutionWorkflow failed",
        prompt_id: prompt_id,
        error_class: e.class.to_s,
        error: e.message
      )
      raise_if_canceled!(e)
      fail_recovery_action(
        recovery_action_id,
        :workflow_failed,
        { error_class: e.class.to_s, error_message: e.message },
        detached: true
      )
      raise
    end

    private

    def fail_recovery_action(recovery_action_id, status, result = {}, detached: false)
      return unless recovery_action_id

      if detached
        run_cleanup_activity(
          Activities::MarkQualityRecoveryActionActivity,
          {
            recovery_action_id: recovery_action_id,
            result: result.merge(status: status)
          },
          timeout: 30
        )
      else
        run_activity(
          Activities::MarkQualityRecoveryActionActivity,
          {
            recovery_action_id: recovery_action_id,
            result: result.merge(status: status)
          },
          timeout: 30
        )
      end
    end
  end
end
