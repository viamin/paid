# frozen_string_literal: true

module Activities
  # Attempts to resolve detected conflicts between parallel agent run branches.
  #
  # Called by ParallelAgentExecutionWorkflow after DetectConflictsActivity
  # identifies overlapping file changes. Applies the configured resolution
  # strategy (auto_rebase, re_run, or manual).
  #
  # Input:
  #   detection_result: Output from DetectConflictsActivity
  #   project_id: Project ID for context
  #   strategy: Resolution strategy (auto_rebase, re_run, manual)
  #
  # Output:
  #   resolved: Boolean indicating whether all conflicts were resolved
  #   strategy: The strategy that was applied
  #   resolutions: Array of per-pair resolution outcomes
  #   requires_manual_review: Boolean if any pair needs human intervention
  class ResolveConflictsActivity < BaseActivity
    activity_name "ResolveConflicts"

    def execute(input)
      detection_result = input.fetch(:detection_result)
      project_id = input.fetch(:project_id)
      requested_strategy = input[:strategy]

      logger.info(
        message: "conflicts.resolve.started",
        project_id: project_id,
        strategy: requested_strategy.presence || :auto_rebase,
        conflicting_pairs: detection_result[:conflicting_pairs]&.size
      )

      result = Conflicts::Resolve.call(
        detection_result: detection_result,
        project_id: project_id,
        strategy: requested_strategy
      )

      logger.info(
        message: "conflicts.resolve.completed",
        project_id: project_id,
        strategy: result[:strategy],
        resolved: result[:resolved],
        requires_manual_review: result[:requires_manual_review]
      )

      result
    end
  end
end
