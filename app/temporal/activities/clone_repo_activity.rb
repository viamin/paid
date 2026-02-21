# frozen_string_literal: true

module Activities
  # Clones a repository and creates a working branch inside an already-provisioned container.
  #
  # Replaces the host-side CreateWorktreeActivity. Git operations run inside
  # the container, authenticated via the git credential helper proxy.
  class CloneRepoActivity < BaseActivity
    activity_name "CloneRepo"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      container_service = reconnect_container(agent_run)
      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )

      if agent_run.existing_pr?
        branch_name = fetch_pr_branch(agent_run)
        git_ops.clone_and_checkout_branch(branch_name: branch_name)
      else
        git_ops.clone_and_setup_branch
      end

      install_ci_hooks(git_ops, agent_run)
      create_worktree_record(agent_run)

      { agent_run_id: agent_run_id, branch_name: agent_run.branch_name }
    end

    private

    def install_ci_hooks(git_ops, agent_run)
      language = detect_language(agent_run.project)
      lint_cmd = Prompts::BuildForIssue::LANGUAGE_LINT_COMMANDS[language]
      test_cmd = Prompts::BuildForIssue::LANGUAGE_TEST_COMMANDS[language]

      # Skip hook installation when we don't have real lint/test commands
      return unless lint_cmd || test_cmd

      git_ops.install_git_hooks(
        lint_command: lint_cmd || "echo 'no lint configured'",
        test_command: test_cmd || "echo 'no tests configured'"
      )
    end

    def detect_language(project)
      lang = project.detected_language if project.respond_to?(:detected_language)
      lang.presence || "ruby"
    end

    def fetch_pr_branch(agent_run)
      project = agent_run.project
      client = project.github_token.client
      pr = client.pull_request(project.full_name, agent_run.source_pull_request_number)
      pr.head.ref
    end

    def reconnect_container(agent_run)
      Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )
    end

    MAX_WORKTREE_RETRIES = 3

    def create_worktree_record(agent_run, attempts: 0)
      # For existing PR runs the branch name is deterministic, so a finished
      # worktree record from a previous run may still exist. Reclaim it
      # instead of failing on the uniqueness constraint.
      #
      # An active record for the *same* agent_run is a Temporal retry —
      # return it as-is to stay idempotent.
      #
      # Rescue RecordNotUnique to handle the race where two activities
      # both see no existing record and try to insert concurrently.
      agent_run.reload
      existing = Worktree.find_by(
        project_id: agent_run.project_id,
        branch_name: agent_run.branch_name
      )

      if existing.nil?
        Worktree.create!(
          project: agent_run.project,
          agent_run: agent_run,
          path: "/workspace",
          branch_name: agent_run.branch_name,
          base_commit: agent_run.base_commit_sha,
          status: "active"
        )
      elsif existing.active? && existing.agent_run_id == agent_run.id
        # Temporal retry — the previous attempt already created this record.
        existing
      elsif existing.active?
        raise Temporalio::Error::ApplicationError.new(
          "Branch #{agent_run.branch_name} has an active worktree from agent run #{existing.agent_run_id}",
          type: "WorktreeConflict"
        )
      else
        # Reclaim cleaned or cleanup_failed records from finished runs.
        # Reset created_at so the record isn't immediately flagged as
        # stale/orphaned by cleanup jobs that check created_at age.
        existing.update!(
          agent_run: agent_run,
          path: "/workspace",
          base_commit: agent_run.base_commit_sha,
          status: "active",
          pushed: false,
          cleaned_at: nil,
          created_at: Time.current
        )
        existing
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # RecordNotUnique: lost the race — another activity inserted first.
      # RecordInvalid with uniqueness error: find_by missed the existing
      # record (e.g. stale query cache) but the validation caught it.
      # In both cases, re-fetch and apply the idempotent/conflict logic.
      retryable_uniqueness_error =
        e.is_a?(ActiveRecord::RecordInvalid) &&
        e.record.is_a?(Worktree) &&
        e.record.errors.of_kind?(:branch_name, :taken)

      raise unless e.is_a?(ActiveRecord::RecordNotUnique) || retryable_uniqueness_error
      raise if attempts >= MAX_WORKTREE_RETRIES
      create_worktree_record(agent_run, attempts: attempts + 1)
    end
  end
end
