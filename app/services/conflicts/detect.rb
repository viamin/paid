# frozen_string_literal: true

module Conflicts
  # Detects file-level conflicts between parallel agent run branches.
  #
  # Given a set of completed agent runs from a parallel execution, compares
  # the files modified by each branch to find overlapping changes that would
  # conflict during merge. Uses git diff against each run's base commit to
  # determine modified files without requiring worktrees.
  #
  # @example
  #   result = Conflicts::Detect.call(agent_run_ids: [1, 2, 3], project_id: 42)
  #   result[:has_conflicts]     # => true
  #   result[:conflicting_pairs] # => [{ runs: [1, 2], files: ["src/app.rb"] }]
  class Detect
    class Error < StandardError; end

    # @param agent_run_ids [Array<Integer>] IDs of completed agent runs to check
    # @param project_id [Integer] Project ID for logging context
    # @return [Hash] Detection result with conflict details
    def self.call(agent_run_ids:, project_id: nil)
      new(agent_run_ids: agent_run_ids, project_id: project_id).call
    end

    def initialize(agent_run_ids:, project_id: nil)
      @agent_run_ids = agent_run_ids
      @project_id = project_id
    end

    def call
      runs = load_completed_runs
      return no_conflicts_result if runs.size < 2

      files_by_run = collect_changed_files(runs)
      return no_conflicts_result if files_by_run.empty?

      conflicts = find_overlapping_files(files_by_run)

      {
        has_conflicts: conflicts.any?,
        conflicting_pairs: conflicts,
        files_by_run: files_by_run.transform_values(&:to_a),
        total_runs_checked: runs.size,
        project_id: @project_id
      }
    end

    private

    def load_completed_runs
      AgentRun
        .where(id: @agent_run_ids)
        .where.not(branch_name: nil)
        .where.not(base_commit_sha: nil)
        .where.not(result_commit_sha: nil)
    end

    def collect_changed_files(runs)
      files_by_run = {}

      runs.find_each do |run|
        files = changed_files_for_run(run)
        files_by_run[run.id] = files if files.any?
      end

      files_by_run
    end

    # Determines files changed by a run by comparing base and result commits.
    # Uses the agent run's recorded SHAs rather than live git operations,
    # since containers may have been cleaned up.
    def changed_files_for_run(run)
      return Set.new if run.base_commit_sha == run.result_commit_sha

      files = diff_files_from_container(run)
      return files if files.any?

      # Fallback: use stored metadata if container is gone
      diff_files_from_metadata(run)
    end

    # Attempts to get changed files from the agent's container if still available.
    def diff_files_from_container(run)
      return Set.new if run.container_id.blank?

      result = run.execute_in_container(
        [ "git", "diff", "--name-only", run.base_commit_sha, run.result_commit_sha ],
        timeout: 30,
        stream: false
      )

      return Set.new unless result.success?

      Set.new(result[:stdout].to_s.strip.split("\n").reject(&:blank?))
    rescue StandardError => e
      Rails.logger.warn(
        message: "conflicts.detect.container_diff_failed",
        agent_run_id: run.id,
        error: e.message
      )
      Set.new
    end

    # Falls back to extracting changed files from agent run logs or phases.
    def diff_files_from_metadata(run)
      # Check if any phase metadata recorded changed files
      phase = run.agent_run_phases.find_by(phase_key: "push_branch")
      if phase&.metadata.is_a?(Hash) && phase.metadata["changed_files"].is_a?(Array)
        return Set.new(phase.metadata["changed_files"])
      end

      Set.new
    end

    def find_overlapping_files(files_by_run)
      run_ids = files_by_run.keys
      conflicts = []

      run_ids.each_with_index do |run_a, i|
        run_ids[(i + 1)..].each do |run_b|
          overlapping = files_by_run[run_a] & files_by_run[run_b]
          next if overlapping.empty?

          conflicts << {
            runs: [ run_a, run_b ],
            files: overlapping.to_a.sort
          }
        end
      end

      conflicts
    end

    def no_conflicts_result
      {
        has_conflicts: false,
        conflicting_pairs: [],
        files_by_run: {},
        total_runs_checked: 0,
        project_id: @project_id
      }
    end
  end
end
