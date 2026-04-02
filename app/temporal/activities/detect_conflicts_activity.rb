# frozen_string_literal: true

module Activities
  # Detects file-level conflicts between completed parallel agent runs.
  #
  # Called by ParallelAgentExecutionWorkflow after all child workflows complete.
  # Compares the files modified by each successful run to identify overlapping
  # changes that would conflict during merge to the base branch.
  #
  # Input:
  #   agent_run_ids: Array of completed agent run IDs to check
  #   project_id: Project ID for logging context
  #
  # Output:
  #   has_conflicts: Boolean indicating whether conflicts were detected
  #   conflicting_pairs: Array of { runs: [id, id], files: [path, ...] }
  #   files_by_run: Hash mapping run ID to list of changed files
  #   total_runs_checked: Number of runs analyzed
  class DetectConflictsActivity < BaseActivity
    activity_name "DetectConflicts"

    def execute(input)
      agent_run_ids = input.fetch(:agent_run_ids, [])
      project_id = input[:project_id]

      logger.info(
        message: "conflicts.detect.started",
        project_id: project_id,
        agent_run_count: agent_run_ids.size
      )

      result = Conflicts::Detect.call(
        agent_run_ids: agent_run_ids,
        project_id: project_id
      )

      logger.info(
        message: "conflicts.detect.completed",
        project_id: project_id,
        has_conflicts: result[:has_conflicts],
        conflicting_pairs_count: result[:conflicting_pairs].size,
        total_runs_checked: result[:total_runs_checked]
      )

      result
    end
  end
end
