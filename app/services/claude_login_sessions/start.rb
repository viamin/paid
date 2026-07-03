# frozen_string_literal: true

module ClaudeLoginSessions
  class Start
    def self.call(...)
      new(...).call
    end

    def initialize(session:, backend: Containers.backend)
      @session = session
      @backend = backend
    end

    def call
      Audit::RecordEvent.call(
        action: "runner.claude_login_started",
        actor: session.created_by,
        subject: session,
        account: session.account,
        metadata: {
          credential_name: session.credential_name,
          details: [ "Started constrained Claude browser login session." ]
        }
      )

      worker = ClaudeLoginSessions::InteractiveLogin.new(session: session, backend: backend)
      worker.start
      worker.wait_for_url
      session.reload
    rescue StandardError => e
      session.fail!(e.message) unless session.terminal?
      Audit::RecordEvent.call(
        action: "runner.claude_login_failed",
        actor: session.created_by,
        subject: session,
        account: session.account,
        metadata: {
          credential_name: session.credential_name,
          details: [ e.message ]
        }
      )
      session
    end

    private

    attr_reader :session, :backend
  end
end
