# frozen_string_literal: true

module CodexLoginSessions
  # Starts a Connect Codex device-code login (RDR-041 / #2962).
  #
  # Requests a device authorization from OpenAI via {OAuthClient} and records the
  # user code + verification URI on the session so the operator can authorize the
  # device out of band. The session transitions to `awaiting_authorization` and a
  # subsequent {Poll} exchanges the device code for tokens once the user approves.
  #
  # Mirrors `ClaudeLoginSessions::Start`: the session is the single source of
  # truth, failures are terminal, and an audit event records the lifecycle. The
  # OAuth client is injectable so the device flow is exercised in tests without
  # real network calls.
  class Start
    def self.call(...)
      new(...).call
    end

    def initialize(session:, client: OAuthClient.new)
      @session = session
      @client = client
    end

    def call
      return session if session.terminal?

      response = client.request_device_code
      session.update!(
        status: "awaiting_authorization",
        device_code: response.device_code,
        user_code: response.user_code,
        verification_uri: response.verification_uri,
        poll_interval: response.interval.positive? ? response.interval : session.poll_interval,
        expires_at: response.expires_in.positive? ? response.expires_in.seconds.from_now : session.expires_at,
        error_message: nil
      )

      Audit::RecordEvent.call(
        action: "runner.codex_login_started",
        actor: session.created_by,
        subject: session,
        account: session.account,
        metadata: {
          credential_name: session.credential_name,
          details: [ "Started Connect Codex device-code login session." ]
        }
      )
      session
    rescue OAuthClient::ConfigurationError, OAuthClient::DeviceRequestError => e
      fail_session!(e.message)
      session
    rescue StandardError => e
      fail_session!(e.message)
      raise
    end

    private

    attr_reader :session, :client

    def fail_session!(message)
      session.fail!(message) unless session.terminal?
      Audit::RecordEvent.call(
        action: "runner.codex_login_failed",
        actor: session.created_by,
        subject: session,
        account: session.account,
        metadata: { credential_name: session.credential_name, details: [ message ] }
      )
    end
  end
end
