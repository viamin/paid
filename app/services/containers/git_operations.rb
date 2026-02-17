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

    # Pushes the agent's branch to the remote.
    #
    # @return [String] the result commit SHA
    # @raise [PushError] when the push fails
    def push_branch
      validate_branch_name!

      result = execute_git("push", "origin", agent_run.branch_name, timeout: PUSH_TIMEOUT)
      raise PushError, "Push failed: #{result.error}" if result.failure?

      sha = fetch_head_sha
      agent_run.update!(result_commit_sha: sha)
      agent_run.worktree&.mark_pushed!

      sha
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
      result = execute_git("rev-parse", "HEAD")
      raise Error, "Failed to get HEAD SHA: #{result.error}" if result.failure?

      result[:stdout].strip
    end

    def fetch_head_sha
      result = execute_git("rev-parse", "HEAD")
      raise Error, "Failed to get HEAD SHA: #{result.error}" if result.failure?

      result[:stdout].strip
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
