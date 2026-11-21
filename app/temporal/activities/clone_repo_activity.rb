# frozen_string_literal: true

module Activities
  # Clones a repository and creates a working branch inside an already-provisioned container.
  #
  # Replaces the host-side CreateWorktreeActivity. Git operations run inside
  # the container, authenticated via the git credential helper proxy.
  class CloneRepoActivity < BaseActivity
    activity_name "CloneRepo"

    include Containers::QualityHooks

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "clone_repo", phase_group: "setup", agent_run: agent_run) do
        container_service = reconnect_container(agent_run)
        git_ops = Containers::GitOperations.new(
          container_service: container_service,
          agent_run: agent_run
        )

        if agent_run.existing_pr?
          heartbeat("clone_repo.fetch_pr_branch", agent_run_id: agent_run_id)
          branch_name = fetch_pr_branch(agent_run)
          with_periodic_heartbeat("clone_repo.checkout_existing_pr", agent_run_id: agent_run_id, branch_name: branch_name) do
            git_ops.clone_and_checkout_branch(
              branch_name: branch_name,
              pull_request_number: agent_run.source_pull_request_number
            )
          end
        else
          with_periodic_heartbeat("clone_repo.setup_branch", agent_run_id: agent_run_id, branch_name: agent_run.branch_name) do
            git_ops.clone_and_setup_branch
          end
        end

        heartbeat("clone_repo.install_hooks", agent_run_id: agent_run_id, branch_name: agent_run.branch_name)
        git_ops.install_artifact_excludes
        install_quality_hooks(git_ops, agent_run)
        git_ops.install_co_author_hook

        heartbeat("clone_repo.codegraph_setup", agent_run_id: agent_run_id)
        Containers::TokenOptimization.codegraph_setup(container_service: container_service)

        # The checkout has to be writable while Paid clones it and installs its
        # own hooks. Seal it only after that setup so the report-only runner
        # cannot alter source or Git metadata.
        # @spec MAINT-020 LAYERED-VERIFY-010
        if agent_run.maintenance_goal? || agent_run.layered_verification_audit_goal?
          container_service.make_workspace_read_only!
        end

        create_worktree_record(agent_run)

        { agent_run_id: agent_run_id, branch_name: agent_run.branch_name }
      end
    end

    private

    def fetch_pr_branch(agent_run)
      project = agent_run.project
      client = project.upstream_pr_target? ? project.git_push_fallback_client || project.client : project.client
      repository = project.upstream_pr_target? ? project.upstream_full_name : project.full_name
      pr = client.pull_request(repository, agent_run.source_pull_request_number)

      unless pr.state == "open"
        raise Temporalio::Error::ApplicationError.new(
          "PR ##{agent_run.source_pull_request_number} is #{pr.state}; project resync needed",
          type: "StalePullRequest",
          non_retryable: true
        )
      end

      verify_upstream_conflict_fix_head!(agent_run, project, pr)
      pr.head.ref
    end

    # Conflict fixes may update only the branch owned by the project's fork.
    # The upstream base is read-only even though the pull request itself is
    # hosted upstream. Reject before checkout, so PushBranch can only ever
    # push to the fork origin cloned for this run. @spec UPSTREAM-GATE-006
    def verify_upstream_conflict_fix_head!(agent_run, project, pr)
      return unless agent_run.focus == "merge_conflict" && project.upstream_pr_target?
      return if pr.head&.repo&.full_name&.casecmp?(project.full_name)

      raise Temporalio::Error::ApplicationError.new(
        "Merge-conflict fixes in upstream mode must target the fork-owned PR head branch",
        type: "UpstreamConflictFixTargetRejected",
        non_retryable: true
      )
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
      elsif existing.active? && reclaimable_for_review_handoff?(existing, agent_run)
        # A producer parked after a verified push owns no live execution
        # resource. A read-only review of that exact PR tip may take over its
        # metadata lease; this does not change the producer's recovery state.
        reclaim_worktree!(existing, agent_run)
      elsif existing.active? && existing.agent_run&.finished?
        # The owning agent run finished (failed/completed) but cleanup never
        # marked the worktree as cleaned. Reclaim the stale record.
        reclaim_worktree!(existing, agent_run)
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

    # A waiting source-closeout producer remains unfinished for bookkeeping,
    # but it is not a writer once its execution references are empty. Review
    # may reuse its branch lease only after checkout has atomically captured
    # the current remote tip for the review run. This keeps a late producer
    # resume, an unverified push, and a changed PR head on the normal conflict
    # path instead of making stale review look current. @spec PR-BRANCH-PUBLISH-013 PR-BRANCH-PUBLISH-014
    def reclaimable_for_review_handoff?(worktree, review_run)
      producer = worktree.agent_run
      return false unless review_run.review_goal? && review_run.existing_pr?
      return false unless producer

      producer.with_lock do
        producer.reload
        return false unless producer.waiting_recovery? && producer.create_pr_goal?
        return false unless producer.branch_name == review_run.branch_name
        return false if producer.temporal_workflow_id.present? || producer.container_id.present? || producer.runner_handle.present?
        return false if producer.service_container_ids.present?
        return false if producer.reconciliation.to_h.dig("source_closure_recovery", "claimed_at").present?

        verified_delivery = producer.result_commit_sha
        verified_delivery.present? && verified_delivery == review_run.expected_remote_head_sha
      end
    end

    def reclaim_worktree!(worktree, agent_run)
      worktree.update!(
        agent_run: agent_run,
        path: "/workspace",
        base_commit: agent_run.base_commit_sha,
        pushed: false,
        cleaned_at: nil,
        created_at: Time.current
      )
      worktree
    end
  end
end
