# frozen_string_literal: true

module CodexLoginSessions
  # Polls a Connect Codex device-code login once and captures the resulting OAuth
  # session into a managed `RunnerCredential` (RDR-041 / #2962).
  #
  # A single call performs one token-endpoint poll (the device-code spec requires
  # the client to honor `interval`/`slow_down`); callers (controller, background
  # poller) drive {call} on a cadence until the session is terminal. On success
  # the OpenAI tokens are normalized into a Codex `auth.json` payload and stored
  # as the canonical encrypted `RunnerCredential#token`, so subsequent runs can be
  # materialized without a host bind mount.
  class Poll
    Result = Data.define(:status, :error_message) do
      def completed? = status == :completed
      def pending? = status == :pending
      def failed? = status == :failed
    end

    def self.call(...)
      new(...).call
    end

    def initialize(session:, client: OAuthClient.new)
      @session = session
      @client = client
    end

    def call
      return Result.new(status: :failed, error_message: session.error_message || "session is terminal") if session.terminal?
      return fail_with!("This Connect Codex login session has expired.") if session.expired?
      return fail_with!("Connect Codex login has not started a device code yet.") if session.device_code.blank?

      response = client.poll_token(session.device_code)
      handle(response)
    rescue OAuthClient::ConfigurationError => e
      fail_with!(e.message)
    rescue StandardError => e
      fail_with!(e.message)
      raise
    end

    private

    attr_reader :session, :client

    def handle(response)
      case response.status
      when :success then capture!(response.tokens)
      when :pending, :slow_down then pending(response)
      else fail_with!(response.error || "token request failed")
      end
    end

    def pending(response)
      back_off_interval! if response.status == :slow_down
      Result.new(status: :pending, error_message: nil)
    end

    def back_off_interval!
      current = session.poll_interval.to_i
      session.update!(poll_interval: (current.positive? ? current : 5) + 5)
    end

    def capture!(tokens)
      auth_json = CodexCredentials::Secret.build(tokens)
      return fail_with!("Connect Codex login did not return a usable OAuth session.") if auth_json.blank?

      parsed = CodexCredentials::Secret.parse(auth_json)
      return fail_with!("Connect Codex login did not return a usable OAuth session.") unless parsed.codex_auth?

      credential = existing_or_new_runner_credential
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

      session.update!(
        runner_credential: credential,
        status: "completed",
        completed_at: Time.current,
        error_message: nil,
        expires_at: parsed.expires_at
      )

      Audit::RecordEvent.call(
        action: "runner.codex_login_completed",
        actor: session.created_by,
        subject: credential,
        account: session.account,
        metadata: {
          credential_name: session.credential_name,
          details: [ "Captured Codex OAuth credential via device-code login." ]
        }
      )
      Result.new(status: :completed, error_message: nil)
    end

    def existing_or_new_runner_credential
      session.account.runner_credentials.find_or_initialize_by(
        runner_key: "codex",
        name: session.credential_name
      )
    end

    def fail_with!(message)
      session.fail!(message) unless session.terminal?
      Result.new(status: :failed, error_message: message)
    end
  end
end
