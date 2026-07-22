# frozen_string_literal: true

module Previews
  # Stops preview sessions whose TTL has passed (RDR-045).
  #
  # Releases tunnel ports back to the pool by transitioning the session to
  # {PreviewSession::TERMINAL_STATUSES} via {PreviewSession#mark_stopped!}.
  # Runs as a periodic job (see {PreviewSessions::ExpireJob}) and can also be
  # invoked scoped to a single project as an opportunistic cleanup.
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
      session.mark_stopped!
      true
    rescue StandardError => e
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
