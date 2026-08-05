# frozen_string_literal: true

module Previews
  # Tears down a preview session's live infrastructure (tunnel port reservation
  # + preview container) from the persisted session record.
  #
  # The provisioning worker (PreviewSessions::ProvisionJob) tears down through
  # Previews::Provision#cleanup! because it holds the live Provision instance
  # with its container service. Every other stop path — the project preview
  # start/restart/stop actions and the per-session stop action — holds only the
  # session record, so it routes through here to release the tunnel port back to
  # the pool and remove the preview container immediately, instead of leaving
  # both alive until a later orphan sweep. Without this, repeated restarts leak
  # tunnel port reservations (exhausting the port pool) and keep serving a
  # preview the UI reports as stopped.
  #
  # Both operations are idempotent and best-effort: a missing reservation or an
  # already-removed container is a no-op, and failures are logged rather than
  # raised so a stop request never strands a session in a non-terminal state.
  class Teardown
    def self.call(session, backend: Containers.backend, logger: Rails.logger)
      new(session, backend:, logger:).call
    end

    def initialize(session, backend: Containers.backend, logger: Rails.logger)
      @session = session
      @backend = backend
      @logger = logger
    end

    def call
      release_tunnel_port!
      remove_container!
    end

    private

    attr_reader :session, :backend, :logger

    # Released by reservation key (preview_session:<id>) so it still works after
    # the session row's tunnel_port has been cleared, and is a no-op when no
    # reservation exists (e.g. the session never finished provisioning a tunnel).
    def release_tunnel_port!
      Previews::TunnelManager.release_port(key: reservation_key)
    rescue StandardError => e
      logger.warn(
        message: "previews.teardown.tunnel_release_failed",
        preview_session_id: session.id,
        error: e.message
      )
    end

    def remove_container!
      return if session.container_id.blank?

      container = backend.get_container(session.container_id)
      backend.stop_container(container, timeout: 0) if container_running?(container)
      backend.delete_container(container, force: true, v: true)
    rescue Docker::Error::NotFoundError
      # Container already removed — nothing to clean up.
    rescue Docker::Error::DockerError => e
      logger.warn(
        message: "previews.teardown.container_remove_failed",
        preview_session_id: session.id,
        container_id: session.container_id,
        error: e.message
      )
    end

    def reservation_key
      "preview_session:#{session.id}"
    end

    def container_running?(container)
      container.info.dig("State", "Running") == true
    rescue Docker::Error::DockerError
      false
    end
  end
end
