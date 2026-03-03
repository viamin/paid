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

    # Marker comment used as a grep guard so Temporal retries don't
    # duplicate the exclude block.  Defined once and referenced both
    # in CONTAINER_ARTIFACT_EXCLUDES and in install_artifact_excludes.
    CONTAINER_ARTIFACT_EXCLUDES_MARKER = "# -- Container artifact excludes (added by Paid) --"

    # Patterns appended to .git/info/exclude inside agent containers.
    # Prevents build/tool artifacts from being staged by `git add -A`
    # even when the repo's .gitignore doesn't cover them.
    CONTAINER_ARTIFACT_EXCLUDES = <<~PATTERNS.freeze
      #{CONTAINER_ARTIFACT_EXCLUDES_MARKER}
      # Node/corepack
      .corepack/
      # NOTE: .yarn/cache/, .yarn/unplugged/, and .pnp.* are intentionally
      # omitted — Yarn zero-installs repos commit these by design.
      # Ruby
      vendor/bundle/
      .bundle/
      # PostgreSQL build artifacts
      .pg-install/
      .pg/
      .pgdata/
      .pg_build/
      .pg_data/
      .pg_src/
      # Python
      .venv/
      __pycache__/
      *.pyc
      # APT/package caches
      .apt-cache/
      .cache-pkg/
      # XDG cache (sometimes redirected into workspace)
      .xdg-cache/
      # Generic build/cache (wildcard to catch variants like .tmp-build)
      .cache/
      .tmp/
      .tmp-*/
      .build/
      .*-build/
      .*_build/
      .npm-cache/
      # mise/asdf
      .mise-cache/
      .mise-data/
    PATTERNS

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
    # When the branch has been deleted from the remote (e.g. after a PR merge),
    # falls back to fetching the PR ref (refs/pull/N/head) which GitHub
    # preserves even after branch deletion.
    #
    # @param branch_name [String] The remote branch to check out
    # @param pull_request_number [Integer, nil] PR number for fallback fetch
    # @return [void]
    # @raise [CloneError] when clone or checkout fails
    def clone_and_checkout_branch(branch_name:, pull_request_number: nil)
      clone_repo
      checkout_remote_branch(branch_name, pull_request_number: pull_request_number)
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

      # Fetch current remote state before --force-with-lease to avoid
      # "stale info" rejections when the branch was updated by a prior run.
      if agent_run.existing_pr?
        fetch_branch(agent_run.branch_name)
      end

      # --no-verify skips any pre-push hooks. The push is a system operation
      # that runs after the agent has exited — quality was already enforced
      # by the pre-commit hook during agent execution.
      push_args = [ "push", "--no-verify", "origin", agent_run.branch_name ]
      push_args << "--force-with-lease" if agent_run.existing_pr?

      result = execute_git(*push_args, timeout: PUSH_TIMEOUT)
      raise PushError, "Push failed: #{error_with_stderr(result)}" if result.failure?

      sha = head_sha
      agent_run.update!(result_commit_sha: sha)
      agent_run.worktree&.mark_pushed!

      sha
    end

    # Installs a pre-commit git hook inside the container.
    #
    # The pre-commit hook runs lint + tests so the agent gets immediate
    # feedback and can fix issues before the commit succeeds. No pre-push
    # hook is installed because the push is a system operation that runs
    # after the agent has exited — the agent cannot fix push-time failures.
    #
    # Checks whether the command binary is on PATH before running (via
    # `command -v`); when the binary is missing the hook prints a warning
    # and exits successfully.
    # Existing hooks (from Husky, Lefthook, etc.) are never overwritten.
    #
    # @param lint_command [String] command to run for linting
    # @param test_command [String] command to run for tests
    # @return [void]
    def install_git_hooks(lint_command:, test_command:)
      install_hook("pre-commit", pre_commit_script(lint_command, test_command))
    rescue Error => e
      # Expected failures: hook write/chmod failed, unsafe command, etc.
      Rails.logger.warn(
        message: "container_git.install_hooks_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    rescue StandardError => e
      # Unexpected failures: container gone, network error, etc.
      Rails.logger.error(
        message: "container_git.install_hooks_unexpected_error",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
    end

    # Installs local git exclude patterns for common build artifacts.
    #
    # Writes to .git/info/exclude, which acts like .gitignore but is local
    # to the clone and never committed. This prevents tool installation
    # artifacts (corepack, pg builds, vendor bundles, etc.) from being
    # accidentally staged by `git add -A` — even if the repo's own
    # .gitignore doesn't cover them.
    #
    # Idempotent: a grep guard skips the append when the marker comment
    # is already present, so Temporal retries don't duplicate entries.
    #
    # @return [void]
    def install_artifact_excludes
      script = "mkdir -p .git/info\n" \
               "if ! grep -qF '#{CONTAINER_ARTIFACT_EXCLUDES_MARKER}' .git/info/exclude 2>/dev/null; then\n" \
               "cat >> .git/info/exclude << 'EXCLUDES'\n" \
               "#{CONTAINER_ARTIFACT_EXCLUDES}" \
               "EXCLUDES\n" \
               "fi"
      result = container_service.execute(script, timeout: nil, stream: false)
      if result.failure?
        Rails.logger.warn(
          message: "container_git.install_excludes_failed",
          agent_run_id: agent_run.id,
          error: error_with_stderr(result)
        )
      end
    rescue StandardError => e
      Rails.logger.error(
        message: "container_git.install_excludes_unexpected_error",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
    end

    # Stages and commits any uncommitted changes left by the agent.
    #
    # Agents sometimes edit files without committing. This ensures those
    # changes are captured in a commit so they survive the push step.
    #
    # Uses --no-verify because this is a safety net that runs after the
    # agent has exited — the agent cannot fix hook failures at this point.
    # The pre-commit hook already had its chance during agent execution.
    #
    # @return [Boolean] true if a commit was created, false if working tree was clean
    def commit_uncommitted_changes
      status_result = execute_git("status", "--porcelain")
      return false unless status_result.success? && status_result[:stdout].present?

      add_result = execute_git("add", "-A")
      raise Error, "Failed to stage changes: #{error_with_stderr(add_result)}" if add_result.failure?

      commit_result = execute_git("commit", "--no-verify", "-m", "Apply agent changes")
      raise Error, "Failed to commit changes: #{error_with_stderr(commit_result)}" if commit_result.failure?

      true
    end

    # Returns the current HEAD SHA from the container.
    #
    # @return [String] the full SHA
    # @raise [Error] when the command fails
    def head_sha
      result = execute_git("rev-parse", "HEAD")
      raise Error, "Failed to get HEAD SHA: #{error_with_stderr(result)}" if result.failure?

      result[:stdout].strip
    end

    # Checks whether the agent made any changes since a specific commit.
    #
    # Detects both new commits (via git log) and uncommitted working-tree
    # changes (via git status). This avoids false positives on existing PR
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
        message: "container_git.has_changes_since_failed",
        agent_run_id: agent_run.id,
        commit_sha: commit_sha,
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

    # Fetches a remote branch inside the container.
    #
    # @param branch [String] The branch to fetch
    # @return [void]
    # @raise [Error] when the fetch fails
    def fetch_branch(branch)
      result = execute_git("fetch", "origin", branch)
      raise Error, "Fetch failed: #{error_with_stderr(result)}" if result.failure?
    end

    # Rebases the current branch onto a remote branch.
    #
    # Fetches the target branch first, then runs git rebase. On conflict,
    # aborts the rebase and returns false so the caller can instruct the
    # agent to resolve conflicts via merge instead.
    #
    # @param onto_branch [String] The branch to rebase onto (e.g. "main")
    # @return [Boolean] true if rebase succeeded, false if conflicts occurred
    def rebase_onto(onto_branch)
      fetch_branch(onto_branch)

      result = execute_git("rebase", "origin/#{onto_branch}")
      if rebase_conflict?(result)
        abort_rebase
        return false
      end

      if result.failure?
        abort_rebase
        raise Error, "Rebase failed: #{error_with_stderr(result)}"
      end

      true
    end

    private

    def rebase_conflict?(result)
      result.failure? &&
        (result[:stdout].to_s.include?("CONFLICT") || result[:stderr].to_s.include?("CONFLICT"))
    end

    def abort_rebase
      execute_git("rebase", "--abort")
    rescue Error
      # Best effort — abort may fail if rebase state is already gone
    end

    def clone_repo
      # Idempotent: skip clone if a previous attempt already populated /workspace.
      # This prevents failures on Temporal retries when the clone succeeded but a
      # later step (e.g. DB update) failed.
      check = execute_git("rev-parse", "--is-inside-work-tree")
      return if check.success?

      project = agent_run.project
      url = "https://github.com/#{project.full_name}.git"

      result = execute_git("clone", url, ".", timeout: CLONE_TIMEOUT)
      raise CloneError, "Clone failed: #{error_with_stderr(result)}" if result.failure?
    end

    def checkout_remote_branch(branch_name, pull_request_number: nil)
      # Use "git switch" for branch switching; "git checkout -- <name>" enters
      # pathspec (file-restore) mode and won't switch branches.
      # "--" separates options from the branch operand so names starting with
      # "-" are never misinterpreted as flags.
      result = execute_git("switch", "--", branch_name)
      return if result.success?

      # Branch may have been deleted from the remote (e.g. after PR merge).
      # Fall back to fetching the PR ref which GitHub preserves.
      raise CloneError, "Checkout failed: #{error_with_stderr(result)}" unless pull_request_number

      fetch_result = execute_git("fetch", "origin", "refs/pull/#{pull_request_number}/head:#{branch_name}")
      raise CloneError, "Checkout failed (branch deleted, PR fetch also failed): #{error_with_stderr(fetch_result)}" if fetch_result.failure?

      checkout_result = execute_git("switch", "--", branch_name)
      raise CloneError, "Checkout failed after PR fetch: #{error_with_stderr(checkout_result)}" if checkout_result.failure?
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
      raise Error, "Branch creation failed: #{error_with_stderr(result)}" if result.failure?

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

    def install_hook(hook_name, script)
      hook_path = ".git/hooks/#{hook_name}"

      # Don't overwrite existing hooks (e.g. from Husky or Lefthook)
      check = container_service.execute("test -f #{hook_path}", timeout: nil, stream: false)
      if check.success?
        Rails.logger.info(
          message: "container_git.hook_exists",
          agent_run_id: agent_run.id,
          hook: hook_name
        )
        return
      end

      write_result = container_service.execute(
        "cat > #{hook_path} << 'HOOKEOF'\n#{script}\nHOOKEOF",
        timeout: nil, stream: false
      )
      raise Error, "Failed to write #{hook_name} hook: #{write_result.error}" if write_result.failure?

      chmod_result = container_service.execute("chmod +x #{hook_path}", timeout: nil, stream: false)
      raise Error, "Failed to chmod #{hook_name} hook: #{chmod_result.error}" if chmod_result.failure?
    end

    # Validates that a shell command is a simple executable with arguments.
    # Each word must be an alphanumeric token, path, or flag — no shell
    # operators (||, &&, ;, |, $, `, etc.) can appear.
    # Commands are expected from LANGUAGE_*_COMMANDS constants, but this
    # provides defense-in-depth against injection if the source changes.
    SAFE_WORD_PATTERN = /\A[a-zA-Z0-9_\-\/\.]+\z/

    def validate_hook_command!(command)
      words = command.split
      raise Error, "Hook command is blank" if words.empty?
      return if words.all? { |w| w.match?(SAFE_WORD_PATTERN) }

      raise Error, "Hook command contains unsafe characters: #{command.inspect}"
    end

    def pre_commit_script(lint_command, test_command)
      validate_hook_command!(lint_command)
      validate_hook_command!(test_command)

      <<~SHELL
        #!/bin/sh
        # Installed by Paid — enforce lint + tests before commit
        # All quality checks run here so the agent gets immediate feedback
        # and can fix issues before the commit succeeds.

        if [ -f bin/lint ]; then
          echo "Running bin/lint --staged..."
          bin/lint --staged || exit 1
        elif command -v #{lint_command.split.first} >/dev/null 2>&1; then
          echo "Running #{lint_command}..."
          #{lint_command} || exit 1
        else
          echo "Warning: lint tool not available yet, skipping lint check"
        fi

        if command -v #{test_command.split.first} >/dev/null 2>&1; then
          echo "Running #{test_command}..."
          #{test_command} || exit 1
        else
          echo "Warning: test tool not available, skipping test check"
        fi
      SHELL
    end

    def execute_git(*args, timeout: nil)
      cmd = [ "git" ] + args
      container_service.execute(cmd, timeout: timeout, stream: false)
    end

    # Builds a descriptive error string that includes stderr when available.
    # Without this, errors only show "Command exited with code N" which
    # makes debugging impossible.
    def error_with_stderr(result)
      parts = [ result.error ]
      parts << result[:stderr] if result[:stderr].present?
      parts.join(" — ")
    end
  end
end
