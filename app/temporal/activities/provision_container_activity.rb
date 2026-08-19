# frozen_string_literal: true

module Activities
  # Provisions a Docker container with an empty workspace directory.
  #
  # The container is created before any git operations. Git clone happens
  # inside the container in the subsequent CloneRepoActivity.
  #
  # Idempotent: re-running this activity for a run that already has a live
  # container reuses it instead of creating a duplicate (see
  # AgentRun#provision_container). A periodic heartbeat is sent while
  # provisioning so a workflow cancellation interrupts an in-flight provision
  # promptly (within one heartbeat interval) instead of waiting for
  # start_to_close. The heartbeat does NOT surface a wedged Docker call
  # (e.g. a stuck image pull) any faster than start_to_close: it only proves
  # the Ruby worker thread is alive, not that Docker is making progress, so
  # no heartbeat_timeout is configured for this activity.
  #
  # Cancellation cleanup: Containers::Provision#provision has a SignalException
  # rescue clause (covering Thread#raise(Interrupt)) that runs cleanup and
  # cleanup_workspace_volume before re-raising, so a thread that is alive
  # enough to catch an Interrupt does not orphan the half-created container
  # or workspace volume. Thread#kill (the last-resort path for truly stuck
  # I/O) bypasses ensure/rescue, so drain_worker first persists any
  # in-flight container via AgentRun#recover_in_flight_container! (giving
  # CleanupContainerActivity a recorded id to remove) and the workflow's
  # cleanup ensure-block still falls back to
  # cleanup_orphaned_workspace_volume by name for any residual volume.
  # Both paths together guarantee no leak on cancel.
  class ProvisionContainerActivity < BaseActivity
    activity_name "ProvisionContainer"

    # How often to heartbeat while provisioning. Well under start_to_close so
    # a workflow cancellation interrupts provisioning promptly.
    HEARTBEAT_INTERVAL_SECONDS = 15

    # Grace window given to an in-flight provisioning worker to finish on
    # its own after the activity is canceled, before it is forcibly
    # interrupted.
    CANCEL_GRACE_SECONDS = 5

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "provision_container", phase_group: "setup", agent_run: agent_run) do
        agent_run.ensure_proxy_token!
        # RDR-055: resolve and snapshot the egress policy before any
        # provisioning work so failed provisions remain auditable, and fail
        # closed when unsafe tenant entries were rejected.
        # @spec EGRESS-POLICY-006
        AgentRuns::EgressPolicy::Resolve.resolve_and_persist!(agent_run)
        provision_with_heartbeat(agent_run, planned_container_host: input[:container_host])

        # worktree_path is not yet populated at provision time — git clone
        # happens later in CloneRepoActivity. log_container_context in
        # RunAgentActivity logs worktree_path once it is available.
        logger.info(
          message: "agent_execution.container_provisioned",
          agent_run_id: agent_run_id,
          container_id: agent_run.container_id
        )

        { agent_run_id: agent_run_id }
      end
    end

    private

    # Provisions the container while sending periodic heartbeats so a workflow
    # cancellation interrupts an in-flight provision promptly (within one
    # interval) instead of waiting for start_to_close. Provisioning runs in a
    # background thread; the activity thread emits heartbeats because the
    # Temporal activity context is thread-local. Falls back to a direct call
    # when no activity context is present (e.g. unit tests).
    #
    # The heartbeat only proves the Ruby worker thread is alive; it does not
    # prove Docker pull/create/start is making progress. A wedged Docker call
    # therefore keeps the worker thread alive and the heartbeats keep flowing,
    # so the activity is bounded by start_to_close, not by any heartbeat
    # timeout. No heartbeat_timeout is set on the workflow call site for this
    # reason — relying on one would imply (falsely) that hung pulls surface
    # before start_to_close.
    #
    # Mirrors RunAgentActivity#with_periodic_heartbeat: on cancellation we
    # flag the worker and re-raise CanceledError, then drain the worker in
    # the ensure block (joining first, escalating to Interrupt only if it is
    # still alive) so the propagating CanceledError is not masked by a worker
    # Interrupt.
    def provision_with_heartbeat(agent_run, interval: HEARTBEAT_INTERVAL_SECONDS,
                                 grace_seconds: CANCEL_GRACE_SECONDS, planned_container_host: nil)
      context = Temporalio::Activity::Context.current_or_nil
      return agent_run.provision_container(container_host: planned_container_host) unless context

      tenant_account_id = Current.account&.id
      worker = Thread.new { run_provision_in_context(agent_run, tenant_account_id, planned_container_host: planned_container_host) }
      worker.report_on_exception = false
      canceled = false

      begin
        until worker.join(interval)
          begin
            context.heartbeat("provisioning")
          rescue Temporalio::Error::CanceledError
            canceled = true
            raise
          rescue StandardError
            # Best-effort heartbeat; the next interval retries.
          end
        end
      ensure
        drain_worker(worker, canceled: canceled, grace_seconds: grace_seconds, agent_run: agent_run)
      end

      worker.value
    end

    # Runs the provisioning work on the background thread with the Rails
    # executor, tenant RLS context, and a scoped DB connection so the worker
    # thread does not share the activity thread's thread-local state.
    def run_provision_in_context(agent_run, tenant_account_id, planned_container_host: nil)
      work = proc { agent_run.provision_container(container_host: planned_container_host) }

      db_scoped = proc do
        if defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:connection_pool)
          ActiveRecord::Base.connection_pool.with_connection { work.call }
        else
          work.call
        end
      end

      tenant_scoped = proc do
        if tenant_account_id
          account = TenantContext.with_system_access { Account.find_by(id: tenant_account_id) }
          if account
            TenantContext.with(account, &db_scoped)
          else
            TenantContext.with_system_access(&db_scoped)
          end
        else
          TenantContext.with_system_access(&db_scoped)
        end
      end

      executor = Rails.application.executor if defined?(Rails) && Rails.respond_to?(:application) &&
        Rails.application.respond_to?(:executor)
      executor ? executor.wrap(&tenant_scoped) : tenant_scoped.call
    end

    # Tears down the provisioning worker once the heartbeat loop has exited.
    #
    # On cancellation, give the worker a short grace window to finish on its
    # own before escalating: join first, and only Thread#raise (then
    # Thread#kill as a last resort) if it is still alive. Joining before
    # raising avoids spuriously interrupting a worker that was about to
    # finish.
    #
    # After escalating we poll worker.alive? rather than worker.join: the
    # worker dies with the Interrupt we sent, and Interrupt inherits from
    # SignalException, so Thread#join/#value would re-raise it here and mask
    # the CanceledError already in flight. Polling drains the worker without
    # propagating its exception. Mirrors the interrupted branch of
    # RunAgentActivity#with_periodic_heartbeat.
    #
    # Cleanup on the Interrupt path is delegated to Containers::Provision#provision's
    # SignalException rescue — it runs cleanup + cleanup_workspace_volume
    # before re-raising, so a caught Interrupt never orphans a half-created
    # container or workspace volume. Thread#kill (last resort for a worker
    # truly stuck in an uninterruptible Docker call) bypasses rescue/ensure,
    # so before killing we recover any container the worker already created
    # via AgentRun#recover_in_flight_container! — persisting its id so the
    # workflow's CleanupContainerActivity can remove it instead of leaking it
    # until the orphan janitor runs. Any residual workspace volume is still
    # cleaned up downstream by cleanup_orphaned_workspace_volume (by name
    # when container_id ends up blank).
    def drain_worker(worker, canceled:, grace_seconds: CANCEL_GRACE_SECONDS, agent_run: nil)
      if canceled
        worker.join(grace_seconds)
        return unless worker.alive?

        worker.raise(Interrupt)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace_seconds
        sleep(0.05) while worker.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return unless worker.alive?

        # The worker is stuck in an uninterruptible call, so Thread#kill is the
        # only way to reclaim the thread. recover_in_flight_container! runs on
        # this (activity) thread — safe to call because a worker wedged in
        # blocking I/O is not mutating its Ruby state — and is best-effort so
        # the kill always proceeds even if the recover write fails.
        begin
          agent_run&.recover_in_flight_container!
        rescue StandardError => e
          logger.warn(
            message: "agent_execution.in_flight_container_recover_failed",
            agent_run_id: agent_run&.id,
            error: e.message
          )
        end
        worker.kill
      else
        worker.join
      end
    end
  end
end
