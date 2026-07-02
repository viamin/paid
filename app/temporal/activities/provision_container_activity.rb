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
  # provisioning so a stuck image pull is detected before the full
  # start_to_close timeout.
  class ProvisionContainerActivity < BaseActivity
    activity_name "ProvisionContainer"

    # How often to heartbeat while provisioning. Well under the heartbeat
    # timeout configured at the workflow call site, giving ample margin.
    HEARTBEAT_INTERVAL_SECONDS = 15

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "provision_container", phase_group: "setup", agent_run: agent_run) do
        agent_run.ensure_proxy_token!
        provision_with_heartbeat(agent_run)

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

    # Provisions the container while sending periodic heartbeats so a stuck
    # image pull (the slow part of create/start) is surfaced before the full
    # start_to_close timeout. Provisioning runs in a background thread; the
    # activity thread emits heartbeats because the Temporal activity context
    # is thread-local. Falls back to a direct call when no activity context
    # is present (e.g. unit tests).
    def provision_with_heartbeat(agent_run, interval: HEARTBEAT_INTERVAL_SECONDS)
      context = Temporalio::Activity::Context.current_or_nil
      return agent_run.provision_container unless context

      tenant_account_id = Current.account&.id
      worker = Thread.new { run_provision_in_context(agent_run, tenant_account_id) }
      worker.report_on_exception = false

      begin
        until worker.join(interval)
          begin
            context.heartbeat("provisioning")
          rescue Temporalio::Error::CanceledError
            interrupt_worker(worker)
            raise
          rescue StandardError
            # Best-effort heartbeat; the next interval retries.
          end
        end
      ensure
        worker.join unless $!
      end

      worker.value
    end

    # Runs the provisioning work on the background thread with the Rails
    # executor, tenant RLS context, and a scoped DB connection so the worker
    # thread does not share the activity thread's thread-local state.
    def run_provision_in_context(agent_run, tenant_account_id)
      work = proc { agent_run.provision_container }

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

    # Cooperatively stops the provisioning worker on cancellation so the
    # activity can shut down promptly without leaving a detached thread.
    def interrupt_worker(worker)
      worker.raise(Interrupt) if worker.alive?
      worker.join(5)
      worker.kill if worker.alive?
    end
  end
end
