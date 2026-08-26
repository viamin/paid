# frozen_string_literal: true

module CodexLoginSessions
  # Orchestrates the OpenAI device-code Connect Codex flow (RDR-041 / #2962).
  #
  # Two operations:
  # - `start!` requests a device code and stores the user code/verification URI
  #   the operator must act on.
  # - `poll!` polls the token endpoint once; on success it persists the captured
  #   OAuth state as the canonical Codex `RunnerCredential`.
  #
  # The HTTP layer is injectable so the flow is exercisable in tests without
  # real OAuth endpoints. Provider-specific OAuth details live in
  # `CodexLoginSessions::OAuthClient`/`OAuthConfig`, not in Paid's core.
  class DeviceFlow
    def self.call(...)
      new(...).call
    end

    def initialize(session:, client: nil)
      @session = session
      @client = client || OAuthClient.new
    end

    def call
      start!
    end

    def start!
      device = client.request_device_code
      session.update!(
        device_code: device.device_code,
        user_code: device.user_code,
        verification_uri: device.verification_uri,
        poll_interval: device.interval.positive? ? device.interval : 5,
        expires_at: device.expires_in.positive? ? device.expires_in.seconds.from_now : session.expires_at,
        status: "awaiting_authorization",
        error_message: nil
      )
      Audit::RecordEvent.call(
        action: "runner.codex_login_started",
        actor: session.created_by,
        subject: session,
        account: session.account,
        metadata: { credential_name: session.credential_name,
                    runner_key: session.target_runner_key,
                    details: [ "Started device-code Connect Codex login session." ] }
      )
      session
    rescue StandardError => e
      fail_session!(e.message)
      session
    end

    # Polls the token endpoint once. Returns a result hash the controller can
    # branch on without reaching into private state.
    # @return [Hash] { status: Symbol, completed: Boolean, error: String|nil }
    def poll!(session_token: nil)
      return invalid_session_token_result unless valid_session_token?(session_token)
      return expired_result if session.expired?
      return terminal_result if session.terminal?

      response = client.poll_token(session.device_code)
      case response.status
      when :success then complete!(response.tokens)
      when :pending then mark_polling
      when :slow_down then back_off
      when :denied then fail_session!("authorization_denied")
      else fail_session!(response.error || "token_request_failed")
      end
    rescue OAuthClient::ConfigurationError => e
      fail_session!(e.message)
      { status: :failed, completed: false, error: e.message }
    rescue StandardError => e
      fail_session!(e.message)
      { status: :failed, completed: false, error: e.message }
    end

    private

    attr_reader :session, :client

    def valid_session_token?(candidate)
      return false if candidate.blank?

      ActiveSupport::SecurityUtils.secure_compare(session.session_token.to_s, candidate.to_s)
    rescue StandardError
      false
    end

    def invalid_session_token_result
      { status: :failed, completed: false, error: "The Connect Codex login session token is invalid." }
    end

    def expired_result
      fail_session!("This Connect Codex login session has expired.")
      { status: :failed, completed: false, error: session.error_message }
    end

    def complete!(tokens)
      auth_json = CodexCredentials::Secret.build(tokens)
      return fail_session!("Connect Codex login did not return a usable OAuth session.") if auth_json.blank?

      credential = persist_credential!(auth_json)
      session.update!(
        runner_credential: credential,
        status: "completed",
        completed_at: Time.current,
        expires_at: credential.expires_at,
        error_message: nil
      )
      Audit::RecordEvent.call(
        action: "runner.codex_login_completed",
        actor: session.created_by,
        subject: credential,
        account: session.account,
        metadata: { credential_name: session.credential_name,
                    runner_key: session.target_runner_key,
                    details: [ "Captured Codex OAuth credential via device-code login session." ] }
      )
      { status: :completed, completed: true, error: nil }
    end

    def persist_credential!(auth_json)
      parsed = CodexCredentials::Secret.parse(auth_json)

      credential = session.account.runner_credentials.find_or_initialize_by(
        runner_key: session.target_runner_key,
        name: session.credential_name
      )
      credential.assign_attributes(
        created_by: session.created_by,
        auth_kind: "oauth_token",
        token: auth_json,
        long_lived: false,
        revoked_at: nil,
        expires_at: parsed.expires_at,
        metadata: credential.metadata.to_h.merge(
          "source" => "device_code_login",
          "storage_format" => "codex_auth_json",
          "access_token_expires_at" => parsed.expires_at&.iso8601
        ).compact
      )
      credential.save!
      credential
    end

    def mark_polling
      session.update!(status: "polling") unless session.polling?
      pending_result
    end

    def back_off
      session.update!(poll_interval: (session.poll_interval || 5) + 5)
      { status: :pending, completed: false, error: nil }
    end

    def pending_result
      { status: :pending, completed: false, error: nil }
    end

    def terminal_result
      { status: session.completed? ? :completed : :failed, completed: session.completed?,
        error: session.error_message }
    end

    def fail_session!(message)
      return if session.terminal?

      session.fail!(message)
      Audit::RecordEvent.call(
        action: "runner.codex_login_failed",
        actor: session.created_by,
        subject: session,
        account: session.account,
        metadata: { credential_name: session.credential_name,
                    runner_key: session.target_runner_key,
                    details: Array(message) }
      )
      { status: :failed, completed: false, error: message }
    rescue StandardError
      { status: :failed, completed: false, error: message }
    end
  end
end
