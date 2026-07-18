# frozen_string_literal: true

module Previews
  # Orchestrates the preview session lifecycle (RDR-045, SUB-7).
  #
  # Responsible for state transitions, tunnel-port allocation, and delegating
  # container start/stop to the configured {ContainerBackend}. Only one preview
  # is kept live per project at a time — starting a new one stops the previous.
  class Provision
    Result = Struct.new(:session, :success?, :error, keyword_init: true)

    attr_reader :project, :actor, :port_pool, :container_backend

    def initialize(project:, actor: nil, port_pool: TunnelPortPool.new,
                   container_backend: ContainerBackend::Simulated)
      @project = project
      @actor = actor
      @port_pool = port_pool
      @container_backend = container_backend
    end

    def self.start(...)
      new(...).start
    end

    def self.stop(...)
      new(...).stop
    end

    def self.restart(...)
      new(...).restart
    end

    def self.status(...)
      new(...).status
    end

    def start(branch_name:, ttl_seconds: PreviewSession::DEFAULT_TTL_SECONDS)
      # Opportunistically reap expired sessions so their tunnel ports are
      # returned to the pool before we try to acquire one. The
      # {PreviewSessions::ExpireJob} cron is the primary reaper; this call
      # covers the gap between expiry and the next cron tick.
      expire_stale_sessions!

      project.with_lock do
        previous = current
        stop_previous(previous) if previous

        session = PreviewSession.build_for(project:, branch_name: resolved_branch(branch_name),
                                           created_by: actor, ttl_seconds: ttl_seconds)
        session.status = "provisioning"
        session.save!

        provision(session)
      end
    rescue StandardError => e
      failure_result(e)
    end

    def stop(session: nil)
      session ||= current
      return Result.new(session: nil, success?: true) unless session

      teardown(session)
      Result.new(session:, success?: true)
    rescue StandardError => e
      session&.mark_failed!(e.message)
      Result.new(session:, success?: false, error: e.message)
    end

    def restart(branch_name: nil, ttl_seconds: PreviewSession::DEFAULT_TTL_SECONDS)
      target_branch = branch_name.presence || current&.branch_name || project.default_branch
      stop
      start(branch_name: target_branch, ttl_seconds: ttl_seconds)
    end

    def status
      PreviewSession.for_project(project).recent.first
    end

    private

    def current
      PreviewSession.for_project(project).active.recent.first
    end

    def provision(session)
      session.update!(status: "starting")
      port = port_pool.acquire(session)
      outcome = container_backend.start(session)
      session.mark_ready!(tunnel_port: port, container_id: outcome.container_id)
      Result.new(session:, success?: true)
    rescue StandardError => e
      Rails.logger.warn(message: "previews.provision_failed", preview_session_id: session.id, error: e.message)
      port_pool.release(session)
      session.mark_failed!(e.message)
      Result.new(session:, success?: false, error: e.message)
    end

    def stop_previous(session)
      teardown(session)
    end

    def teardown(session)
      # Always release the tunnel port and mark the session stopped, even if
      # the container backend raises — a leaked port would starve the pool and
      # a stuck `ready` row would block the next start.
      container_backend.stop(session)
    ensure
      port_pool.release(session)
      session.mark_stopped!
    end

    def expire_stale_sessions!
      Expire.call(project: project)
    end

    def resolved_branch(branch_name)
      branch_name.presence || project.default_branch
    end

    def failure_result(error)
      Result.new(session: current, success?: false, error: error.message)
    end
  end
end
