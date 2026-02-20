# frozen_string_literal: true

module Containers
  # Runs git operations inside an agent container via container exec.
  #
  # All git commands execute inside the container, authenticated via the
  # git credential helper that fetches tokens from the secrets proxy.
  # No git credentials are exposed on the host.
  #
  # @example
  #   git_ops = Containers::GitOperations.new(
  #     container_service: container_service,
  #     agent_run: agent_run
  #   )
  #   git_ops.clone_and_setup_branch
  #   git_ops.push_branch
  class GitOperations
    class Error < StandardError; end
    class CloneError < Error; end
    class PushError < Error; end

    CLONE_TIMEOUT = 120
    PUSH_TIMEOUT = 60

    attr_reader :container_service, :agent_run

    def initialize(container_service:, agent_run:)
      @container_service = container_service
      @agent_run = agent_run
    end

    # Clones the repository and creates a new branch inside the container.
    #
    # @return [void]
    # @raise [CloneError] when the clone fails
    def clone_and_setup_branch
      clone_repo
      branch_name = create_branch
      base_sha = record_base_commit

      agent_run.update!(
        worktree_path: "/workspace",
        branch_name: branch_name,
        base_commit_sha: base_sha
      )
    end

    # Clones the repository and checks out an existing remote branch.
    #
    # @param branch_name [String] The remote branch to check out
    # @return [void]
    # @raise [CloneError] when clone or checkout fails
    def clone_and_checkout_branch(branch_name:)
      clone_repo
      checkout_remote_branch(branch_name)
      base_sha = record_merge_base

      agent_run.update!(
        worktree_path: "/workspace",
        branch_name: branch_name,
        base_commit_sha: base_sha
      )
    end

    # Pushes the agent's branch to the remote.
    #
    # Uses --force-with-lease for existing PR branches to safely handle
    # rebased or amended commits while preventing overwriting concurrent
    # changes from other collaborators.
    #
    # @return [String] the result commit SHA
    # @raise [PushError] when the push fails
    def push_branch
      validate_branch_name!

      push_args = [ "push", "origin", agent_run.branch_name ]
      push_args << "--force-with-lease" if agent_run.existing_pr?

      result = execute_git(*push_args, timeout: PUSH_TIMEOUT)
      raise PushError, "Push failed: #{result.error}" if result.failure?

      sha = head_sha
      agent_run.update!(result_commit_sha: sha)
      agent_run.worktree&.mark_pushed!

      sha
    end

    # Returns the current HEAD SHA from the container.
    #
    # @return [String] the full SHA
    # @raise [Error] when the command fails
    def head_sha
      result = execute_git("rev-parse", "HEAD")
      raise Error, "Failed to get HEAD SHA: #{result.error}" if result.failure?

      result[:stdout].strip
    end

    # Checks whether the agent made any changes since a specific commit.
    #
    # Detects both new commits (via git log) and uncommitted working-tree
    # changes (via git diff). This avoids false positives on existing PR
    # branches where prior runs already added commits.
    #
    # @param commit_sha [String] the SHA to compare against (typically HEAD before the agent ran)
    # @return [Boolean]
    def has_changes_since?(commit_sha)
      # Check for new commits since the given SHA
      log_result = execute_git("log", "--oneline", "#{commit_sha}..HEAD")
      return true if log_result.success? && log_result[:stdout].present?

      # Check for any uncommitted changes (staged or unstaged)
      status_result = execute_git("status", "--porcelain")
      status_result.success? && status_result[:stdout].present?
    rescue => e
      Rails.logger.warn(
        message: "container_git.check_changes_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      false
    end

    # Checks whether the agent made any changes.
    #
    # When base_commit_sha is available, compares HEAD against the base to
    # detect new commits. Falls back to checking uncommitted working-tree
    # changes only (no base to compare against).
    #
    # @return [Boolean]
    def has_changes?
      base = agent_run.base_commit_sha
      if base.present?
        result = execute_git("diff", "--stat", base, "HEAD")
      else
        result = execute_git("diff", "--stat", "HEAD")
      end
      result.success? && result[:stdout].present?
    rescue => e
      Rails.logger.warn(
        message: "container_git.check_changes_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      false
    end

    private

    def clone_repo
      # Idempotent: skip clone if a previous attempt already populated /workspace.
      # This prevents failures on Temporal retries when the clone succeeded but a
      # later step (e.g. DB update) failed.
      check = execute_git("rev-parse", "--is-inside-work-tree")
      return if check.success?

      project = agent_run.project
      url = "https://github.com/#{project.full_name}.git"

      result = execute_git("clone", url, ".", timeout: CLONE_TIMEOUT)
      raise CloneError, "Clone failed: #{result.error}" if result.failure?
    end

    def checkout_remote_branch(branch_name)
      result = execute_git("checkout", branch_name)
      raise CloneError, "Checkout failed: #{result.error}" if result.failure?
    end

    def record_merge_base
      project = agent_run.project
      default_branch = project.default_branch || "main"

      result = execute_git("merge-base", default_branch, "HEAD")
      if result.success?
        result[:stdout].strip
      else
        # Fall back to HEAD if merge-base fails (e.g. unrelated histories)
        record_base_commit
      end
    end

    def create_branch
      slug = generate_branch_slug
      suffix = SecureRandom.hex(3)
      branch_name = "paid/#{slug}-#{suffix}"

      result = execute_git("checkout", "-b", branch_name)
      raise Error, "Branch creation failed: #{result.error}" if result.failure?

      branch_name
    end

    def generate_branch_slug
      if agent_run.issue.present?
        "#{agent_run.issue.github_number}-#{slugify(agent_run.issue.title)}"
      elsif agent_run.custom_prompt.present?
        slugify(agent_run.custom_prompt)
      else
        "agent-#{agent_run.id}"
      end
    end

    def slugify(text)
      text
        .downcase
        .gsub(/[^a-z0-9\s-]/, "")
        .strip
        .gsub(/[\s-]+/, "-")
        .truncate(50, omission: "")
        .chomp("-")
    end

    def record_base_commit
      head_sha
    end

    def validate_branch_name!
      raise PushError, "branch_name is blank" if agent_run.branch_name.blank?
    end

    def execute_git(*args, timeout: nil)
      cmd = [ "git" ] + args
      container_service.execute(cmd, timeout: timeout, stream: false)
    end
  end
end
