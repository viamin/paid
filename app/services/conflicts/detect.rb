# frozen_string_literal: true

require "set"

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
      @worktree_services = {}
      @prepared_worktree_project_ids = Set.new
    end

    def call
      runs = load_completed_runs
      return no_conflicts_result(runs_checked: runs.size) if runs.size < 2

      files_by_run = collect_changed_files(runs)

      if files_by_run.empty? && @diff_failures.any?
        return detection_failed_result(runs_checked: runs.size)
      end

      return no_conflicts_result(runs_checked: runs.size) if files_by_run.empty?

      conflicts = find_overlapping_files(files_by_run)

      {
        has_conflicts: conflicts.any? || @diff_failures.any?,
        conflicting_pairs: conflicts,
        files_by_run: files_by_run.map { |agent_run_id, set| { agent_run_id: agent_run_id, files: set.to_a.sort } },
        total_runs_checked: runs.size,
        project_id: @project_id,
        detection_failed: @diff_failures.any?,
        failed_run_ids: @diff_failures,
        requires_manual_review: @diff_failures.any?,
        error: nil
      }
    end

    private

    def load_completed_runs
      scope = AgentRun
        .completed
        .includes(:agent_run_phases, :project)
        .where(id: @agent_run_ids)
        .where.not(branch_name: nil)

      scope = scope.where(project_id: @project_id) if @project_id

      scope
    end

    def collect_changed_files(runs)
      files_by_run = {}
      @diff_failures = []

      runs.find_each do |run|
        files = changed_files_for_run(run)
        files_by_run[run.id] = files if files.any?
      end

      files_by_run
    end

    # Determines files changed by a run by comparing base and result commits.
    # Tries three sources in order:
    #   1. Container git diff (if container still exists)
    #   2. Host bare repo git diff (using stored SHAs)
    #   3. Phase metadata (if changed_files was recorded in any phase)
    #
    # If all sources fail to produce files (and the commits differ),
    # the run is recorded as a diff failure so the caller can require
    # manual review instead of silently reporting no conflicts.
    def changed_files_for_run(run)
      if run.base_commit_sha.blank? || run.result_commit_sha.blank?
        files = diff_files_from_metadata(run)
        return files if files.any?

        @diff_failures << run.id
        return Set.new
      end

      return Set.new if run.base_commit_sha == run.result_commit_sha

      files = diff_files_from_container(run)
      return files if files.any?

      files = diff_files_from_bare_repo(run)
      return files if files.any?

      files = diff_files_from_metadata(run)
      return files if files.any?

      # All sources failed — record so we can flag for manual review
      @diff_failures << run.id
      Set.new
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

    # Computes changed files via the host bare repo using stored commit SHAs.
    # Works even after containers are cleaned up, as long as the commits
    # were pushed to the remote and fetched into the bare clone.
    def diff_files_from_bare_repo(run)
      return Set.new unless run.project

      worktree_service = worktree_service_for(run.project)
      output = worktree_service.run_repo_command(
        "diff", "--name-only", run.base_commit_sha, run.result_commit_sha
      )

      Set.new(output.to_s.strip.split("\n").reject(&:blank?))
    rescue StandardError => e
      Rails.logger.warn(
        message: "conflicts.detect.bare_repo_diff_failed",
        agent_run_id: run.id,
        error: e.message
      )
      Set.new
    end

    def worktree_service_for(project)
      @worktree_services[project.id] ||= begin
        worktree_service = WorktreeService.new(project)
        prepare_worktree_service(project.id, worktree_service)
        worktree_service
      end
    end

    def prepare_worktree_service(project_id, worktree_service)
      return if @prepared_worktree_project_ids.include?(project_id)

      worktree_service.ensure_cloned(max_fetch_age: 2.minutes)
      @prepared_worktree_project_ids << project_id
    end

    # Falls back to extracting changed files from any phase metadata.
    # Searches all phases (not just push_branch) since changed_files
    # may be recorded by different phase types depending on the agent.
    def diff_files_from_metadata(run)
      files = Set.new

      phases = run.agent_run_phases
      return files if phases.blank?

      phases.each do |phase|
        metadata = phase.metadata
        next unless metadata.is_a?(Hash)

        changed_files = metadata["changed_files"] || metadata[:changed_files]
        next unless changed_files.is_a?(Array)

        normalized_files = changed_files.filter_map do |path|
          normalized_path = path.to_s.strip
          normalized_path unless normalized_path.blank?
        end

        files.merge(normalized_files)
      end

      files
    rescue StandardError => e
      Rails.logger.warn(
        message: "conflicts.detect.metadata_diff_failed",
        agent_run_id: run.id,
        error: e.message
      )
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

    def no_conflicts_result(runs_checked: 0)
      {
        has_conflicts: false,
        conflicting_pairs: [],
        files_by_run: [],
        total_runs_checked: runs_checked,
        project_id: @project_id,
        detection_failed: false,
        failed_run_ids: [],
        requires_manual_review: false,
        error: nil
      }
    end

    def detection_failed_result(runs_checked: 0)
      {
        has_conflicts: true,
        conflicting_pairs: [],
        files_by_run: [],
        total_runs_checked: runs_checked,
        project_id: @project_id,
        detection_failed: true,
        failed_run_ids: @diff_failures,
        requires_manual_review: true,
        error: nil
      }
    end
  end
end
