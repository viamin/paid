# frozen_string_literal: true

module Runners
  # Provider adapter registry for managed subscription auth lifecycle
  # decisions (RDR-041). The contract stays intentionally small:
  #
  # - `status(secret:)` classifies a managed credential without mutating it.
  # - `materialize(secret:)` returns the runtime payload the CLI expects.
  # - `refresh(provisioner:)` delegates provider-specific refresh ownership.
  # - `harvest(provisioner:)` delegates provider-specific writeback ownership.
  # - `rotation_risk` / `remote_safe?` expose scheduler-facing facts.
  #
  # Claude, Codex, Gemini, and Copilot each have a concrete adapter. Gemini and
  # Copilot materialize the minimal native CLI config from a managed
  # RunnerCredential (#2964); their refresh/harvest ownership is deferred until
  # telemetry proves reliability, so those methods return unsupported.
  # @spec SUBSCRIPTION-RUNNER-AUTH-001
  # @spec SUBSCRIPTION-RUNNER-AUTH-002
  # @spec SUBSCRIPTION-RUNNER-AUTH-003
  class SubscriptionAuthProviders
    Status = Struct.new(
      :state,
      :expires_at,
      :refreshable,
      :materialization_mode,
      :rotation_risk,
      :remote_safe,
      :redacted_metadata,
      :error,
      keyword_init: true
    ) do
      def valid?
        state == :valid
      end

      def expired?
        state == :expired
      end

      def malformed?
        state == :malformed
      end

      def unsupported?
        state == :unsupported
      end

      def blank?
        state == :blank
      end

      # Tracks credential *presence* rather than materializability. Eligibility
      # classification (Containers::Provision#record_eligibility_attempts!)
      # needs any non-blank managed credential to surface as `:managed` so an
      # expired/non-refreshable credential still reports `credential_state:
      # :expired` instead of silently falling back to `host_forwarded`. A
      # malformed credential is present-but-unusable, so it is included here;
      # the materialization path still rejects it via `materializable?`.
      def present?
        !blank? && !unsupported?
      end

      def materializable?
        valid? || (expired? && refreshable?)
      end

      def refreshable?
        refreshable == true
      end

      def remote_safe?
        remote_safe == true
      end
    end

    Materialization = Struct.new(
      :supported,
      :mode,
      :env,
      :files,
      :redacted_metadata,
      :error,
      keyword_init: true
    ) do
      def supported?
        supported == true
      end
    end

    Result = Struct.new(:supported, :performed, :reason, keyword_init: true) do
      def supported?
        supported == true
      end

      def performed?
        performed == true
      end
    end

    class Base
      attr_reader :runner_key

      def initialize(runner_key:)
        @runner_key = runner_key
      end

      def status(secret:)
        unsupported_status
      end

      def materialize(secret:)
        unsupported_materialization
      end

      def refresh(provisioner:)
        Result.new(supported: false, performed: false, reason: "unsupported")
      end

      def harvest(provisioner:)
        Result.new(supported: false, performed: false, reason: "unsupported")
      end

      def rotation_risk
        materializer&.rotation_risk || SubscriptionAuthMaterializers::ROTATION_UNSUPPORTED
      end

      def remote_safe?
        materializer&.remote_safe? == true
      end

      def materialization_mode
        materializer&.materialization_mode || SubscriptionAuthMaterializers::MATERIALIZE_UNSUPPORTED
      end

      private

      def materializer
        @materializer ||= SubscriptionAuthMaterializers.for_runner(runner_key)
      end

      def unsupported_status
        Status.new(
          state: :unsupported,
          expires_at: nil,
          refreshable: false,
          materialization_mode: materialization_mode,
          rotation_risk: rotation_risk,
          remote_safe: remote_safe?,
          redacted_metadata: { "materialized" => false },
          error: "unsupported"
        )
      end

      def unsupported_materialization
        Materialization.new(
          supported: false,
          mode: materialization_mode,
          env: {},
          files: {},
          redacted_metadata: { "materialized" => false },
          error: "unsupported"
        )
      end

      def blank_status
        Status.new(
          state: :blank,
          expires_at: nil,
          refreshable: false,
          materialization_mode: materialization_mode,
          rotation_risk: rotation_risk,
          remote_safe: remote_safe?,
          redacted_metadata: { "materialized" => false },
          error: "blank"
        )
      end

      def malformed_status
        Status.new(
          state: :malformed,
          expires_at: nil,
          refreshable: false,
          materialization_mode: SubscriptionAuthMaterializers::MATERIALIZE_UNSUPPORTED,
          rotation_risk: SubscriptionAuthMaterializers::ROTATION_UNSUPPORTED,
          remote_safe: false,
          redacted_metadata: { "materialized" => false },
          error: "malformed"
        )
      end

      def malformed_materialization(status)
        Materialization.new(
          supported: false,
          mode: status.materialization_mode,
          env: {},
          files: {},
          redacted_metadata: status.redacted_metadata,
          error: status.error
        )
      end

      def classify_codex_auth_secret(secret)
        value = secret.to_s
        return [ blank_status, nil ] if value.blank?

        parsed = CodexCredentials::Secret.parse(value)
        return [ malformed_status, nil ] unless parsed.codex_auth?
        return [ malformed_status, nil ] if parsed.access_token.blank? && parsed.refresh_token.blank?

        [ codex_auth_status(parsed), parsed ]
      end

      def codex_auth_status(parsed)
        expires_at = parsed.expires_at
        expired = expires_at.present? && expires_at <= Time.current
        Status.new(
          state: expired ? :expired : :valid,
          expires_at: expires_at,
          refreshable: parsed.refresh_token.present?,
          materialization_mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          rotation_risk: SubscriptionAuthMaterializers::ROTATION_CONTAINER_MAY_ROTATE,
          remote_safe: remote_safe?,
          redacted_metadata: parsed.redacted_metadata,
          error: expired ? "expired" : nil
        )
      end
    end

    class Claude < Base
      CREDENTIALS_PATH = "/home/agent/.claude/.credentials.json"
      OAUTH_ENV_KEY = "CLAUDE_CODE_OAUTH_TOKEN"

      def initialize
        super(runner_key: "claude")
      end

      def status(secret:)
        classify(secret).first
      end

      def materialize(secret:)
        status, parsed = classify(secret)
        return unsupported_materialization if status.unsupported?
        return malformed_materialization(status) unless status.materializable?

        if parsed.long_lived_token?
          return Materialization.new(
            supported: true,
            mode: SubscriptionAuthMaterializers::MATERIALIZE_ENV,
            env: { OAUTH_ENV_KEY => parsed.oauth_token.to_s },
            files: {},
            redacted_metadata: status.redacted_metadata,
            error: nil
          )
        end

        Materialization.new(
          supported: true,
          mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          env: {},
          files: { CREDENTIALS_PATH => parsed.credentials_json },
          redacted_metadata: status.redacted_metadata,
          error: nil
        )
      end

      def refresh(provisioner:)
        # `refresh_claude_subscription_credential!` delegates to
        # `refresh_claude_credentials_if_near_expiry!` which never returns
        # literal `true`: it returns `nil` on early-exit paths and an
        # `AuthAttemptRecorder::Result` when a refresh runs. Coerce to a
        # boolean so the contract (and keep-warm telemetry) reflects whether a
        # refresh attempt actually executed, matching the previous `!!refreshed`
        # inline coercion.
        performed = !!provisioner.refresh_claude_subscription_credential!
        Result.new(
          supported: true,
          performed: performed,
          reason: performed ? "refreshed" : "refresh_failed"
        )
      end

      def harvest(provisioner:)
        Result.new(supported: false, performed: false, reason: "unsupported")
      end

      private

      # Parses `secret` exactly once and returns `[Status, Parsed]`. Both
      # `status` and `materialize` delegate here so the credential is never
      # parsed twice for the same call.
      def classify(secret)
        value = secret.to_s
        return [ blank_status, nil ] if value.blank?

        parsed = ClaudeCredentials::Secret.parse(value)
        return [ malformed_status, nil ] if malformed_secret?(value, parsed)

        if parsed.long_lived_token?
          return [ Status.new(
            state: :valid,
            expires_at: nil,
            refreshable: false,
            materialization_mode: SubscriptionAuthMaterializers::MATERIALIZE_ENV,
            rotation_risk: SubscriptionAuthMaterializers::ROTATION_SERVER_REFRESH_ONLY,
            remote_safe: true,
            redacted_metadata: {
              "materialized" => true,
              "kind" => "long_lived_token",
              "has_refresh_token" => false,
              "has_expiry" => false
            },
            error: nil
          ), parsed ]
        end

        return [ malformed_status, nil ] unless parsed.oauth_token.present?

        expires_at = parsed.expires_at
        expired = expires_at.present? && expires_at <= Time.current
        [ Status.new(
          state: expired ? :expired : :valid,
          expires_at: expires_at,
          refreshable: parsed.refresh_token.present?,
          materialization_mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          rotation_risk: SubscriptionAuthMaterializers::ROTATION_SERVER_REFRESH_ONLY,
          remote_safe: true,
          redacted_metadata: parsed.redacted_metadata,
          error: expired ? "expired" : nil
        ), parsed ]
      end

      def malformed_secret?(value, parsed)
        return false unless value.lstrip.start_with?("{", "[")

        !parsed.native_credentials_json?
      rescue JSON::ParserError
        true
      end
    end

    # Codex managed subscription auth (RDR-041 / #2962). The stored secret is the
    # Codex CLI's native `auth.json` (OAuth state nested under `tokens`). The CLI
    # may rotate `auth.json` in-container, so refresh and harvest ownership is
    # delegated to the provisioner, which holds a per-credential lease through
    # the run and writes rotated state back into the canonical `RunnerCredential`.
    #
    # Remote placement stays gated by the materializer registry (`remote_safe?
    # == false`) until refresh/writeback is proven by tests and telemetry.
    class Codex < Base
      AUTH_PATH = "/home/agent/.codex/auth.json"

      def initialize
        super(runner_key: "codex")
      end

      def status(secret:)
        classify(secret).first
      end

      def materialize(secret:)
        status, parsed = classify(secret)
        return unsupported_materialization if status.unsupported?
        return malformed_materialization(status) unless status.materializable?

        Materialization.new(
          supported: true,
          mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          env: {},
          files: { AUTH_PATH => parsed.auth_json },
          redacted_metadata: status.redacted_metadata,
          error: nil
        )
      end

      def refresh(provisioner:)
        performed = !!provisioner.refresh_codex_managed_credential!
        Result.new(
          supported: true,
          performed: performed,
          reason: performed ? "refreshed" : "refresh_skipped"
        )
      end

      def harvest(provisioner:)
        provisioner.harvest_codex_managed_credential!
      end

      private

      def classify(secret)
        classify_codex_auth_secret(secret)
      end
    end

    class OpenCode < Base
      AUTH_PATH = "/home/agent/.local/share/opencode/auth.json"

      def initialize
        super(runner_key: "opencode")
      end

      def status(secret:)
        classify(secret).first
      end

      def materialize(secret:)
        status, parsed = classify(secret)
        return unsupported_materialization if status.unsupported?
        return malformed_materialization(status) unless status.materializable?

        Materialization.new(
          supported: true,
          mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          env: {},
          files: { AUTH_PATH => build_auth_json(parsed) },
          redacted_metadata: status.redacted_metadata,
          error: nil
        )
      end

      def refresh(provisioner:)
        performed = !!provisioner.refresh_opencode_managed_credential!
        Result.new(
          supported: true,
          performed: performed,
          reason: performed ? "refreshed" : "refresh_skipped"
        )
      end

      def harvest(provisioner:)
        provisioner.harvest_opencode_managed_credential!
      end

      private

      def classify(secret)
        classify_codex_auth_secret(secret)
      end

      def build_auth_json(parsed)
        JSON.generate(
          "openai" => {
            "type" => "oauth",
            "access" => parsed.access_token,
            "refresh" => parsed.refresh_token,
            "expires" => expires_ms(parsed),
            "accountId" => parsed.account_id
          }.compact
        )
      end

      def expires_ms(parsed)
        parsed.expires_at&.then { |expires_at| (expires_at.to_f * 1000).to_i }
      end
    end

    class Omp < Base
      IMPORT_PATH = "/home/agent/.local/share/omp/paid-auth-import.json"

      def initialize
        super(runner_key: "omp")
      end

      def status(secret:)
        classify(secret).first
      end

      def materialize(secret:)
        status, parsed = classify(secret)
        return unsupported_materialization if status.unsupported?
        return malformed_materialization(status) unless status.materializable?

        Materialization.new(
          supported: true,
          mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          env: {},
          files: { IMPORT_PATH => build_import_json(parsed) },
          redacted_metadata: status.redacted_metadata,
          error: nil
        )
      end

      private

      def classify(secret)
        value = secret.to_s
        return [ blank_status, nil ] if value.blank?

        parsed = ClaudeCredentials::Secret.parse(value)
        return [ malformed_status, nil ] unless parsed.native_credentials_json?
        return [ malformed_status, nil ] if parsed.oauth_token.blank?

        expires_at = parsed.expires_at
        expired = expires_at.present? && expires_at <= Time.current
        [ Status.new(
          state: expired ? :expired : :valid,
          expires_at: expires_at,
          refreshable: parsed.refresh_token.present?,
          materialization_mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          rotation_risk: SubscriptionAuthMaterializers::ROTATION_CONTAINER_MAY_ROTATE,
          remote_safe: remote_safe?,
          redacted_metadata: parsed.redacted_metadata,
          error: expired ? "expired" : nil
        ), parsed ]
      end

      def build_import_json(parsed)
        JSON.generate(
          "type" => "claude",
          "access_token" => parsed.oauth_token,
          "refresh_token" => parsed.refresh_token,
          "expired" => parsed.expires_at&.utc&.iso8601
        )
      end
    end

    # Gemini managed subscription auth (RDR-041 / #2964). The stored secret is
    # the Gemini CLI's native `~/.gemini/oauth_creds.json` (a Google OAuth
    # access/refresh token payload). The adapter regenerates only the fields
    # the CLI reads for authentication, so a managed credential can carry a run
    # to a remote Docker backend without a host bind mount.
    #
    # Refresh and harvest are deferred until a provider login flow and
    # lease-through-run harvest land (#2964 follow-up), so those methods return
    # the unsupported contract result.
    class Gemini < Base
      CREDS_PATH = "/home/agent/.gemini/oauth_creds.json"

      def initialize
        super(runner_key: "gemini")
      end

      def status(secret:)
        classify(secret).first
      end

      def materialize(secret:)
        status, parsed = classify(secret)
        return unsupported_materialization if status.unsupported?
        return malformed_materialization(status) unless status.materializable?

        Materialization.new(
          supported: true,
          mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          env: {},
          files: { CREDS_PATH => parsed.oauth_creds_json },
          redacted_metadata: status.redacted_metadata,
          error: nil
        )
      end

      private

      def blank_status
        Status.new(
          state: :blank,
          expires_at: nil,
          refreshable: false,
          materialization_mode: materialization_mode,
          rotation_risk: rotation_risk,
          remote_safe: remote_safe?,
          redacted_metadata: { "materialized" => false },
          error: "blank"
        )
      end

      def malformed_materialization(status)
        Materialization.new(
          supported: false,
          mode: status.materialization_mode,
          env: {},
          files: {},
          redacted_metadata: status.redacted_metadata,
          error: status.error
        )
      end

      # GeminiCredentials::Secret treats any non-oath JSON payload as blank
      # (no malformed distinction), so classify only needs blank vs valid/expired.
      def classify(secret)
        value = secret.to_s
        return [ blank_status, nil ] if value.blank?

        parsed = GeminiCredentials::Secret.parse(value)
        return [ blank_status, nil ] unless parsed.oauth_credentials?
        return [ blank_status, nil ] if parsed.access_token.blank? && parsed.refresh_token.blank?

        expires_at = parsed.expires_at
        expired = expires_at.present? && expires_at <= Time.current
        [ Status.new(
          state: expired ? :expired : :valid,
          expires_at: expires_at,
          refreshable: parsed.refresh_token.present?,
          materialization_mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          rotation_risk: SubscriptionAuthMaterializers::ROTATION_CONTAINER_MAY_ROTATE,
          remote_safe: remote_safe?,
          redacted_metadata: parsed.redacted_metadata,
          error: expired ? "expired" : nil
        ), parsed ]
      end
    end

    # Copilot managed subscription auth (RDR-041 / #2964). The stored secret is
    # the Copilot CLI's native `~/.copilot/config.json`, whose OAuth token may
    # live under any of the keys the CLI has used across versions. The adapter
    # regenerates a minimal config carrying only the OAuth token plus non-secret
    # lifecycle hints, so a managed credential can carry a run to a remote
    # Docker backend without a host bind mount.
    #
    # Refresh and harvest are deferred until a provider login flow and
    # lease-through-run harvest land (#2964 follow-up), so those methods return
    # the unsupported contract result.
    class Copilot < Base
      CONFIG_PATH = "/home/agent/.copilot/config.json"

      def initialize
        super(runner_key: "copilot")
      end

      def status(secret:)
        classify(secret).first
      end

      def materialize(secret:)
        status, parsed = classify(secret)
        return unsupported_materialization if status.unsupported?
        return malformed_materialization(status) unless status.materializable?

        Materialization.new(
          supported: true,
          mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          env: {},
          files: { CONFIG_PATH => parsed.config_json },
          redacted_metadata: status.redacted_metadata,
          error: nil
        )
      end

      private

      def blank_status
        Status.new(
          state: :blank,
          expires_at: nil,
          refreshable: false,
          materialization_mode: materialization_mode,
          rotation_risk: rotation_risk,
          remote_safe: remote_safe?,
          redacted_metadata: { "materialized" => false },
          error: "blank"
        )
      end

      def malformed_materialization(status)
        Materialization.new(
          supported: false,
          mode: status.materialization_mode,
          env: {},
          files: {},
          redacted_metadata: status.redacted_metadata,
          error: status.error
        )
      end

      # CopilotCredentials::Secret treats any non-Copilot JSON payload as blank
      # (no malformed distinction), so classify only needs blank vs valid/expired.
      def classify(secret)
        value = secret.to_s
        return [ blank_status, nil ] if value.blank?

        parsed = CopilotCredentials::Secret.parse(value)
        return [ blank_status, nil ] unless parsed.copilot_config?
        return [ blank_status, nil ] if parsed.oauth_token.blank?

        expires_at = parsed.expires_at
        expired = expires_at.present? && expires_at <= Time.current
        [ Status.new(
          state: expired ? :expired : :valid,
          expires_at: expires_at,
          refreshable: parsed.refresh_token.present?,
          materialization_mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          rotation_risk: SubscriptionAuthMaterializers::ROTATION_CONTAINER_MAY_ROTATE,
          remote_safe: remote_safe?,
          redacted_metadata: parsed.redacted_metadata,
          error: expired ? "expired" : nil
        ), parsed ]
      end
    end

    REGISTRY = {
      "claude" => Claude.new,
      "codex" => Codex.new,
      "opencode" => OpenCode.new,
      "omp" => Omp.new,
      "gemini" => Gemini.new,
      "copilot" => Copilot.new
    }.freeze

    class << self
      def for_runner(runner_key)
        REGISTRY[runner_key.to_s]
      end
    end
  end
end
