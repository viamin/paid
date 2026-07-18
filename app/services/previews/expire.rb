# frozen_string_literal: true

module Previews
  # Stops preview sessions whose TTL has passed (RDR-045).
  #
  # Without this reaper, expired `active` rows would keep their tunnel ports
  # claimed indefinitely, starving the pool. Called opportunistically from
  # {Provision.start} (so the very next request cleans up) and from the
  # {PreviewSessions::ExpireJob} cron (so idle projects get reaped too).
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
      Provision.new(project: session.project).stop(session: session)
    rescue StandardError => e
      Rails.logger.warn(
        message: "previews.expire_failed",
        preview_session_id: session.id,
        error: e.message
      )
      session.mark_failed!(e.message) unless session.failed?
    end
  end
end
