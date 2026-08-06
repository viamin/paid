# frozen_string_literal: true

module Previews
  # Stops preview sessions whose TTL has passed (RDR-045).
  #
  # Routes every expiring session through {Previews::Teardown} before
  # transitioning it to {PreviewSession::TERMINAL_STATUSES} via
  # {PreviewSession#mark_stopped!}, so the tunnel port reservation is released
  # back to the pool and the preview container is removed immediately rather than
  # lingering past TTL until a later orphan sweep. Runs as a periodic job (see
  # {PreviewSessions::ExpireJob}) and can also be invoked scoped to a single
  # project as an opportunistic cleanup.
  class Expire
    def self.call(...)
      new(...).call
    end

    attr_reader :project

    def initialize(project: nil)
      @project = project
    end

    def call
      expired.find_each { |session| stop_session(session) }
    end

    private

    def expired
      scope = PreviewSession.expiring_before(Time.current)
      scope = scope.where(project_id: project) if project
      scope
    end

    def stop_session(session)
      Previews::Teardown.call(session)
      session.mark_stopped!
      true
    rescue Previews::Lifecycle::Error => e
      Rails.logger.warn(
        message: "previews.expire_failed",
        preview_session_id: session.id,
        error: e.message
      )
      session.mark_failed!(e.message) unless session.failed?
      false
    end
  end
end
