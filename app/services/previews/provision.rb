# frozen_string_literal: true

module Previews
  # Orchestrates the preview session lifecycle (RDR-045, SUB-7).
  #
  # Responsible for state transitions, tunnel-port allocation, and delegating
  # container start/stop to the configured {ContainerBackend}. Only one preview
  # is kept live per project at a time — starting a new one stops the previous.
  class Provision
    Result = Struct.new(:session, :success?, :error, keyword_init: true) do
      def success?
        self[:success?]
      end
    end

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
      previous = current
      stop_previous(previous) if previous

      session = PreviewSession.build_for(project:, branch_name: resolved_branch(branch_name),
                                         created_by: actor, ttl_seconds: ttl_seconds)
      session.status = "provisioning"
      session.save!

      provision(session)
    rescue StandardError => e
      failure_result(e)
    end

    def stop
      session = current
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
      port = port_pool.acquire
      outcome = container_backend.start(session)
      session.mark_ready!(tunnel_port: port, container_id: outcome.container_id)
      Result.new(session:, success?: true)
    rescue StandardError => e
      Rails.logger.warn(message: "previews.provision_failed", preview_session_id: session.id, error: e.message)
      release_port(session)
      session.mark_failed!(e.message)
      Result.new(session:, success?: false, error: e.message)
    end

    def stop_previous(session)
      teardown(session)
    end

    def teardown(session)
      container_backend.stop(session)
      release_port(session)
      session.mark_stopped!
    end

    def release_port(session)
      port_pool.release(session.tunnel_port)
      session.update_column(:tunnel_port, nil) if session.tunnel_port.present?
    end

    def resolved_branch(branch_name)
      branch_name.presence || project.default_branch
    end

    def failure_result(error)
      Result.new(session: current, success?: false, error: error.message)
    end
  end
end
