# frozen_string_literal: true

require "base64"
require "digest"
require "tmpdir"

module Runners
  # Shared refresh/lease/harvest lifecycle for managed (rotating) subscription
  # RunnerCredentials (RDR-041 / #2962). Extracted from Containers::Provision so
  # standalone text execution — Api::StandaloneTextCredentialsController and
  # Containers::StandaloneTextExecutor — runs the same credential lifecycle as
  # provisioned agent runs instead of a drifting copy:
  #
  # - A near-expiry credential is refreshed server-side under a per-credential
  #   row lease (RunnerCredential#with_lock) before materialization.
  # - A CLI rotation written to the native auth file inside a container is
  #   harvested back into the canonical RunnerCredential after the run, under
  #   the same per-credential lockfile lease the provisioner uses, so runs
  #   sharing one credential serialize against each other.
  #
  # Size note: the three rotating runners' lifecycles are deliberately
  # co-located in one service because their storage formats differ while the
  # refresh/lease/harvest protocol is shared; splitting them would multiply the
  # call sites this extraction exists to unify.
  # @spec SUBSCRIPTION-RUNNER-AUTH-002 SUBSCRIPTION-RUNNER-AUTH-005 LLM-ROUTING-005
  class ManagedCredentialLifecycle
    ROTATING_RUNNER_KEYS = %w[codex opencode omp].freeze
    REFRESH_WINDOW_SECONDS = 600
    DEFAULT_LOCK_TIMEOUT_SECONDS = 30
    LOCKFILE_BASE_PATHS = {
      "codex" => "/tmp/codex-managed-auth",
      "opencode" => "/tmp/opencode-managed-auth",
      "omp" => "/tmp/omp-managed-auth"
    }.freeze

    class Error < StandardError; end

    # Raised when a refresh exchange returns a payload that is not usable
    # native auth state; the canonical credential is left untouched.
    class InvalidRefreshResponse < Error
      attr_reader :reason

      def initialize(message = nil, reason: "unusable")
        @reason = reason
        super(message)
      end
    end

    Result = SubscriptionAuthProviders::Result

    class << self
      def rotating?(runner_key)
        ROTATING_RUNNER_KEYS.include?(runner_key.to_s)
      end

      def refresh_supported?(runner_key)
        exchange_key = runner_key.to_s == "omp" ? :claude : runner_key.to_s.to_sym
        AgentHarness::Authentication.respond_to?(:exchange_refresh_token) &&
          AgentHarness::Authentication.respond_to?(:exchange_refresh_token_supported?) &&
          AgentHarness::Authentication.exchange_refresh_token_supported?(exchange_key)
      end

      def near_expiry?(credential, runner_key:)
        return false unless credential

        expiry = credential.expires_at || parsed_secret(credential, runner_key: runner_key)&.expires_at
        return false if expiry.nil?

        expiry <= REFRESH_WINDOW_SECONDS.seconds.from_now
      end

      # Refreshes the canonical credential under a per-credential row lease when
      # its access token is near expiry. With +provision:+ true (materialization
      # follows immediately) the post-lock re-check is bypassed so the
      # materialized auth reflects the token current at window entry, matching
      # Containers::Provision#refresh_codex_managed_credential_with_lease!.
      # Exchange failures are non-fatal and reported as :refresh_failed; the
      # caller proceeds with the existing token, as the provisioner does.
      def refresh_if_near_expiry!(credential, runner_key:, provision: false)
        return :no_credential unless credential
        return :not_rotating unless rotating?(runner_key)
        return :not_needed unless near_expiry?(credential, runner_key: runner_key)

        credential.with_lock do
          if provision || near_expiry?(credential.reload, runner_key: runner_key)
            exchange_refresh_token!(credential, runner_key: runner_key) ? :refreshed : :refresh_failed
          else
            :not_needed
          end
        end
      rescue AgentHarness::AuthenticationError, AgentHarness::Error, Error, ArgumentError,
             JSON::ParserError, SystemCallError => e
        Rails.logger.warn(message: "runners.managed_credential_lifecycle.refresh_failed",
          runner_key: runner_key, credential_id: credential&.id, error_class: e.class.name)
        :refresh_failed
      end

      # Performs the provider refresh exchange and persists the rotated state
      # into the canonical credential. Raises InvalidRefreshResponse (or the
      # harness errors) on failure; callers that need a non-raising outcome use
      # refresh_if_near_expiry! instead.
      def exchange_refresh_token!(credential, runner_key:)
        payload = case runner_key.to_s
        when "codex", "opencode"
          AgentHarness::Authentication.exchange_refresh_token(runner_key.to_sym).to_h
        when "omp"
          exchange_omp_refresh_token(credential)
        else
          raise ArgumentError, "Unsupported managed refresh runner: #{runner_key}"
        end
        apply_refresh_result!(credential, runner_key: runner_key, payload: payload)
        true
      end

      # Reads the CLI's native auth state from a container and persists any
      # rotation back into the canonical credential. Never raises for
      # per-rotation failures; the outcome is reported through the result.
      def harvest(credential:, runner_key:, backend:, container:)
        return Result.new(supported: false, performed: false, reason: "unsupported") unless rotating?(runner_key) && credential

        stdout, _stderr, status = backend.exec_in_container(container, rotation_read_command(runner_key), user: "agent")
        return Result.new(supported: true, performed: false, reason: "harvest_failed") unless status.to_i.zero?

        persist_rotation!(credential, runner_key: runner_key, raw: Array(stdout).join)
      rescue Docker::Error::DockerError, SystemCallError => e
        Rails.logger.warn(message: "runners.managed_credential_lifecycle.harvest_failed",
          runner_key: runner_key, credential_id: credential&.id, error_class: e.class.name)
        Result.new(supported: true, performed: false, reason: "harvest_failed")
      end

      def rotation_read_command(runner_key)
        case runner_key.to_s
        when "codex" then [ "sh", "-lc", "base64 -w0 /home/agent/.codex/auth.json" ]
        when "opencode" then [ "sh", "-lc", "base64 -w0 /home/agent/.local/share/opencode/auth.json" ]
        when "omp" then [ "python3", "-c", OMP_ROTATION_READ_SCRIPT ]
        else
          raise ArgumentError, "Unsupported managed harvest runner: #{runner_key}"
        end
      end

      # Processes raw harvest exec output and persists a valid rotation.
      # Returns the provider Result contract (reasons match the provisioner's
      # telemetry codes) instead of raising for known bad rotations.
      def persist_rotation!(credential, runner_key:, raw:)
        case runner_key.to_s
        when "codex" then persist_codex_rotation!(credential, raw)
        when "opencode" then persist_opencode_rotation!(credential, raw)
        when "omp" then persist_omp_rotation!(credential, raw)
        else
          raise ArgumentError, "Unsupported managed harvest runner: #{runner_key}"
        end
      rescue ArgumentError, JSON::ParserError => e
        Rails.logger.warn(message: "runners.managed_credential_lifecycle.rotation_rejected",
          runner_key: runner_key, credential_id: credential&.id, error_class: e.class.name)
        Result.new(supported: true, performed: false, reason: "harvest_failed")
      end

      # Deterministic per-credential lockfile for the managed auth lease. Keyed
      # identically to Containers::Provision#managed_auth_lockfile_path so
      # standalone text runs and agent-run provisions sharing one credential
      # serialize against each other on the same host.
      def managed_auth_lockfile_path(runner_key:, credential:)
        base_path = LOCKFILE_BASE_PATHS.fetch(runner_key.to_s, "#{Dir.tmpdir}/#{runner_key}-managed-auth")
        credential_id = credential&.id
        return "#{base_path}-missing.lock" unless credential_id

        digest = Digest::SHA256.hexdigest("#{runner_key}-managed:#{credential_id}")[0, 16]
        "#{base_path}-#{digest}.lock"
      end

      # Holds the per-credential lockfile lease around one container exec so
      # concurrent runs sharing the credential cannot interleave rotations. On
      # lock timeout the block proceeds unlocked (matching
      # Containers::Provision#with_subscription_managed_auth_lock) and the
      # outcome is surfaced as a warning.
      def with_managed_auth_lease(runner_key:, credential:, timeout: DEFAULT_LOCK_TIMEOUT_SECONDS)
        lockfile = managed_auth_lockfile_path(runner_key: runner_key, credential: credential)
        File.open(lockfile, File::WRONLY | File::CREAT, 0o600) do |file|
          unless acquire_lock_with_timeout(file, timeout)
            Rails.logger.warn(message: "runners.managed_credential_lifecycle.lease_timeout",
              runner_key: runner_key, credential_id: credential&.id, lock_timeout_seconds: timeout)
            next yield
          end

          begin
            yield
          ensure
            file.flock(File::LOCK_UN)
          end
        end
      end

      private

      def parsed_secret(credential, runner_key:)
        token = credential.token.to_s
        return nil if token.blank?

        case runner_key.to_s
        when "omp" then ClaudeCredentials::Secret.parse(token)
        when "codex", "opencode" then CodexCredentials::Secret.parse(token)
        end
      end

      def exchange_omp_refresh_token(credential)
        refreshed_payload = nil
        Dir.mktmpdir("paid-omp-managed-auth-") do |dir|
          credentials_path = File.join(dir, ".credentials.json")
          File.write(credentials_path, credential.token.to_s)
          with_env("CLAUDE_CONFIG_DIR", dir) do
            AgentHarness::Authentication.exchange_refresh_token(:claude)
          end
          refreshed_payload = File.read(credentials_path)
        end
        refreshed_payload
      end

      def with_env(key, value)
        previous = ENV[key]
        ENV[key] = value
        yield
      ensure
        previous.nil? ? ENV.delete(key) : ENV[key] = previous
      end

      def apply_refresh_result!(credential, runner_key:, payload:)
        case runner_key.to_s
        when "codex" then apply_codex_refresh_result!(credential, payload)
        when "opencode" then apply_opencode_refresh_result!(credential, payload)
        when "omp" then apply_omp_refresh_result!(credential, payload)
        else
          raise ArgumentError, "Unsupported managed refresh runner: #{runner_key}"
        end
      end

      # A successful refresh must yield usable native auth (an access token).
      # Reject blank/non-native or refresh-token-only payloads before touching
      # the canonical credential, otherwise an unexpected upstream exchange
      # overwrites the stored token with garbage (#2962 review).
      def apply_codex_refresh_result!(credential, payload)
        token = payload.is_a?(Hash) ? payload.dig(:token) || JSON.generate(payload) : payload.to_s
        parsed = CodexCredentials::Secret.parse(token.to_s)
        unless parsed.codex_auth? && parsed.access_token.present?
          raise InvalidRefreshResponse.new("Codex refresh response is not a usable auth.json",
            reason: parsed.codex_auth? ? "missing_access_token" : "not_codex_auth")
        end

        credential.assign_attributes(
          token: token.to_s,
          expires_at: parsed.expires_at || credential.expires_at,
          revoked_at: nil,
          metadata: credential.metadata.to_h.merge(
            "source" => "server_refresh",
            "storage_format" => "codex_auth_json",
            "access_token_expires_at" => (parsed.expires_at || credential.expires_at)&.iso8601
          ).compact
        )
        credential.save!
      end

      def apply_opencode_refresh_result!(credential, payload)
        token = payload.is_a?(Hash) ? payload.dig(:token) || JSON.generate(payload) : payload.to_s
        parsed = OpencodeCredentials::Secret.parse(token.to_s)
        canonical_auth = parsed.codex_auth_json
        unless parsed.opencode_auth? && parsed.access_token.present? && canonical_auth.present?
          raise InvalidRefreshResponse.new("OpenCode refresh response is not a usable auth.json",
            reason: parsed.opencode_auth? ? "missing_access_token" : "not_opencode_auth")
        end

        credential.assign_attributes(
          token: canonical_auth,
          expires_at: parsed.expires_at || credential.expires_at,
          revoked_at: nil,
          metadata: credential.metadata.to_h.merge(
            "source" => "server_refresh",
            "storage_format" => "codex_auth_json",
            "access_token_expires_at" => (parsed.expires_at || credential.expires_at)&.iso8601
          ).compact
        )
        credential.save!
      end

      def apply_omp_refresh_result!(credential, payload)
        parsed = ClaudeCredentials::Secret.parse(payload.to_s)
        raise ArgumentError, "OMP refresh response is not a Claude credentials payload" unless parsed.native_credentials_json?
        raise ArgumentError, "OMP refresh response is missing an access token" if parsed.oauth_token.blank?

        credential.assign_attributes(
          token: parsed.credentials_json,
          expires_at: parsed.expires_at || credential.expires_at,
          revoked_at: nil,
          metadata: credential.metadata.to_h.merge(
            "source" => "server_refresh",
            "storage_format" => "claude_credentials_json",
            "access_token_expires_at" => (parsed.expires_at || credential.expires_at)&.iso8601,
            "subscription_type" => parsed.subscription_type,
            "scopes" => parsed.scopes.presence
          ).compact
        )
        credential.save!
      end

      def persist_codex_rotation!(credential, raw_stdout)
        encoded = raw_stdout.to_s
        return Result.new(supported: true, performed: false, reason: "no_rotated_credential") if encoded.blank?

        rotated = Base64.strict_decode64(encoded)
        parsed = CodexCredentials::Secret.parse(rotated)
        # A rotation without an access token is not harvestable: persisting it
        # would brick the next materialization (#2962 review).
        return rejection_result("malformed_rotated_credential") unless parsed.codex_auth?

        return rejection_result("rotated_credential_missing_access_token") unless parsed.access_token.present?

        update_credential_from_rotation!(credential, token: rotated,
          expires_at: parsed.expires_at || credential.expires_at, storage_format: "codex_auth_json")
      end

      def persist_opencode_rotation!(credential, raw_stdout)
        encoded = raw_stdout.to_s
        return Result.new(supported: true, performed: false, reason: "no_rotated_credential") if encoded.blank?

        rotated = Base64.strict_decode64(encoded)
        parsed = OpencodeCredentials::Secret.parse(rotated)
        return rejection_result("malformed_rotated_credential") unless parsed.opencode_auth?

        return rejection_result("rotated_credential_missing_access_token") unless parsed.access_token.present?

        canonical_auth = parsed.codex_auth_json
        raise ArgumentError, "OpenCode rotation is missing canonical auth material" if canonical_auth.blank?

        update_credential_from_rotation!(credential, token: canonical_auth,
          expires_at: parsed.expires_at || credential.expires_at, storage_format: "codex_auth_json")
      end

      def persist_omp_rotation!(credential, raw_stdout)
        payload = raw_stdout.to_s.strip
        return Result.new(supported: true, performed: false, reason: "no_rotated_credential") if payload.blank?

        rotated = JSON.parse(payload)
        return rejection_result("rotated_credential_missing_access_token") unless rotated["access"].present?

        expires_at = parse_omp_rotation_expiry(rotated["expires"])
        current = ClaudeCredentials::Secret.parse(credential.token.to_s)
        update_credential_from_rotation!(credential, token: JSON.generate("claudeAiOauth" => {
          "accessToken" => rotated["access"],
          "refreshToken" => rotated["refresh"],
          "expiresAt" => (expires_at || credential.expires_at)&.utc&.iso8601,
          "subscriptionType" => current.subscription_type,
          "scopes" => current.scopes.presence
        }.compact), expires_at: expires_at || credential.expires_at,
          storage_format: "claude_credentials_json",
          extra_metadata: { "subscription_type" => current.subscription_type, "scopes" => current.scopes.presence })
      end

      def update_credential_from_rotation!(credential, token:, expires_at:, storage_format:, extra_metadata: {})
        credential.assign_attributes(
          token: token,
          expires_at: expires_at,
          last_used_at: Time.current,
          revoked_at: nil,
          metadata: credential.metadata.to_h.merge(
            "source" => "container_rotation_harvest",
            "storage_format" => storage_format,
            "access_token_expires_at" => expires_at&.iso8601
          ).merge(extra_metadata).compact
        )
        credential.save!
        Result.new(supported: true, performed: true, reason: "harvested")
      end

      def rejection_result(reason)
        Result.new(supported: true, performed: false, reason: reason)
      end

      def parse_omp_rotation_expiry(raw)
        return nil if raw.blank?

        Time.at(Integer(raw) / 1000.0).utc
      rescue ArgumentError, TypeError
        nil
      end

      def acquire_lock_with_timeout(file, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          return true if file.flock(File::LOCK_EX | File::LOCK_NB)

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining <= 0

          sleep [ remaining, 0.5 ].min
        end
      end
    end

    OMP_ROTATION_READ_SCRIPT = <<~'PYTHON'.freeze
      import sqlite3
      db = "/home/agent/.local/share/omp/agent/agent.db"
      conn = sqlite3.connect(db)
      try:
        row = conn.execute(
          "SELECT data FROM auth_credentials WHERE provider = ? AND credential_type = ? ORDER BY id DESC LIMIT 1",
          ("anthropic", "oauth"),
        ).fetchone()
        print("" if row is None else row[0])
      finally:
        conn.close()
    PYTHON
    private_constant :OMP_ROTATION_READ_SCRIPT
  end
end
