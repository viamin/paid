# frozen_string_literal: true

module Conflicts
  # Attempts to resolve detected conflicts between parallel agent branches.
  #
  # Supports three resolution strategies:
  #   - :auto_rebase  - Rebase conflicting branches sequentially onto each other,
  #                     falling back to manual review when rebase is not possible
  #   - :re_run       - Mark conflicting runs for re-execution against updated base
  #   - :manual       - Flag conflicts for human review
  #
  # The resolver processes conflicting pairs. With :auto_rebase it will attempt
  # an automatic rebase first; if that fails (for example due to true semantic
  # conflicts or missing runs/containers), it flags the pair for manual review.
  #
  # @example
  #   result = Conflicts::Resolve.call(
  #     detection_result: detection,
  #     project_id: 42,
  #     strategy: :auto_rebase
  #   )
  class Resolve
    class Error < StandardError; end

    STRATEGIES = %i[auto_rebase re_run manual].freeze

    # @param detection_result [Hash] Output from Conflicts::Detect
    # @param project_id [Integer] Project ID for context
    # @param strategy [Symbol] Resolution strategy to use
    # @return [Hash] Resolution result with per-pair outcomes
    def self.call(detection_result:, project_id:, strategy: :auto_rebase)
      new(
        detection_result: detection_result,
        project_id: project_id,
        strategy: strategy
      ).call
    end

    def initialize(detection_result:, project_id:, strategy: :auto_rebase)
      @detection_result = detection_result
      @project_id = project_id
      @strategy = strategy.to_sym

      unless STRATEGIES.include?(@strategy)
        raise ArgumentError, "Unknown strategy: #{@strategy}. Must be one of: #{STRATEGIES.join(", ")}"
      end
    end

    def call
      unless @detection_result[:has_conflicts]
        return {
          resolved: true,
          strategy: @strategy,
          resolutions: [],
          project_id: @project_id,
          requires_manual_review: false
        }
      end

      resolutions = resolve_conflicts
      all_resolved = resolutions.all? { |r| r[:resolved] }

      log_resolution_result(resolutions, all_resolved)

      {
        resolved: all_resolved,
        strategy: @strategy,
        resolutions: resolutions,
        project_id: @project_id,
        requires_manual_review: resolutions.any? { |r| r[:action] == :manual }
      }
    end

    private

    def resolve_conflicts
      @detection_result[:conflicting_pairs].map do |pair|
        resolve_pair(pair)
      end
    end

    def resolve_pair(pair)
      case @strategy
      when :auto_rebase
        attempt_auto_rebase(pair)
      when :re_run
        mark_for_rerun(pair)
      when :manual
        flag_for_manual_review(pair)
      end
    end

    def attempt_auto_rebase(pair)
      run_ids = pair[:runs]
      files = pair[:files]

      # Load runs ordered by completion time — the earlier run becomes the base.
      # Scope to project_id to prevent cross-project operations.
      scope = AgentRun.where(id: run_ids)
      scope = scope.where(project_id: @project_id) if @project_id
      runs = scope.order(:completed_at, :id)
      base_run = runs.first
      rebase_run = runs.last

      return manual_fallback(pair, "runs_not_found") unless base_run && rebase_run && base_run.id != rebase_run.id

      # Attempt rebase via the container if still available
      if rebase_run.container_id.present?
        rebase_result = attempt_rebase_in_container(rebase_run, base_run)
        if rebase_result[:success]
          return {
            runs: run_ids,
            files: files,
            resolved: true,
            action: :rebased,
            rebased_run_id: rebase_run.id,
            base_run_id: base_run.id
          }
        end
      end

      # Rebase failed or container unavailable — fall back
      manual_fallback(pair, "rebase_failed")
    end

    def attempt_rebase_in_container(rebase_run, base_run)
      return { success: false, error: "no_container" } if rebase_run.container_id.blank?
      return { success: false, error: "no_branch" } if base_run.branch_name.blank?

      git_ops = Containers::GitOperations.new(
        container_service: reconnect_container(rebase_run),
        agent_run: rebase_run
      )

      success = git_ops.rebase_onto(base_run.branch_name)

      unless success
        return { success: false, error: "conflicts" }
      end

      push_success = push_rebased_branch(git_ops, rebase_run, base_run)
      { success: push_success, error: push_success ? nil : "push_failed" }
    rescue StandardError => e
      Rails.logger.warn(
        message: "conflicts.resolve.rebase_failed",
        agent_run_id: rebase_run.id,
        base_run_id: base_run.id,
        error: e.message
      )
      { success: false, error: e.message }
    end

    def reconnect_container(run)
      Containers::Provision.reconnect(
        agent_run: run,
        container_id: run.container_id,
        worktree_path: run.worktree_path
      )
    end

    def push_rebased_branch(git_ops, rebase_run, base_run)
      git_ops.push_branch
      true
    rescue StandardError => e
      Rails.logger.warn(
        message: "conflicts.resolve.push_failed_after_rebase",
        agent_run_id: rebase_run.id,
        base_run_id: base_run.id,
        error: e.message
      )
      false
    end

    def mark_for_rerun(pair)
      run_ids = pair[:runs]
      files = pair[:files]

      # Select rerun target by completion time to avoid relying on detection order.
      # Scope to project_id for consistency with attempt_auto_rebase.
      target_run_id = begin
        scope = AgentRun.where(id: run_ids)
        scope = scope.where(project_id: @project_id) if @project_id
        runs = scope.order(:completed_at, :id)
        runs.last&.id || run_ids.last
      rescue StandardError
        run_ids.last
      end

      {
        runs: run_ids,
        files: files,
        resolved: true,
        action: :re_run,
        re_run_ids: [ target_run_id ]
      }
    end

    def flag_for_manual_review(pair)
      {
        runs: pair[:runs],
        files: pair[:files],
        resolved: false,
        action: :manual,
        message: "Conflicting files require manual resolution"
      }
    end

    def manual_fallback(pair, reason)
      {
        runs: pair[:runs],
        files: pair[:files],
        resolved: false,
        action: :manual,
        message: "Auto-rebase failed: #{reason}"
      }
    end

    def log_resolution_result(resolutions, all_resolved)
      Rails.logger.info(
        message: "conflicts.resolve.completed",
        project_id: @project_id,
        strategy: @strategy,
        total_pairs: resolutions.size,
        resolved_count: resolutions.count { |r| r[:resolved] },
        all_resolved: all_resolved
      )
    end
  end
end
