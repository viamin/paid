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
  # Claude is the first fully wired adapter here. Other providers keep an
  # explicit unsupported adapter entry until their lifecycle work lands.
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

      def materializable?
        valid?
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
    end

    class Claude < Base
      CREDENTIALS_PATH = "/home/agent/.claude/.credentials.json"
      OAUTH_ENV_KEY = "CLAUDE_CODE_OAUTH_TOKEN"

      def initialize
        super(runner_key: "claude")
      end

      def status(secret:)
        value = secret.to_s
        return blank_status if value.blank?

        parsed = ClaudeCredentials::Secret.parse(value)
        return malformed_status if malformed_secret?(value, parsed)

        if parsed.long_lived_token?
          return Status.new(
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
          )
        end

        return malformed_status unless parsed.oauth_token.present?

        expires_at = parsed.expires_at
        expired = expires_at.present? && expires_at <= Time.current
        Status.new(
          state: expired ? :expired : :valid,
          expires_at: expires_at,
          refreshable: parsed.refresh_token.present?,
          materialization_mode: SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          rotation_risk: SubscriptionAuthMaterializers::ROTATION_SERVER_REFRESH_ONLY,
          remote_safe: true,
          redacted_metadata: parsed.redacted_metadata,
          error: expired ? "expired" : nil
        )
      end

      def materialize(secret:)
        status = self.status(secret: secret)
        return unsupported_materialization if status.unsupported?

        parsed = ClaudeCredentials::Secret.parse(secret)
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
        performed = provisioner.send(:refresh_claude_credentials_if_near_expiry!)
        Result.new(
          supported: true,
          performed: performed == true,
          reason: performed ? "refreshed" : "refresh_failed"
        )
      end

      def harvest(provisioner:)
        Result.new(supported: false, performed: false, reason: "unsupported")
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

      def malformed_secret?(value, parsed)
        return false unless value.lstrip.start_with?("{", "[")

        !parsed.native_credentials_json?
      rescue JSON::ParserError
        true
      end
    end

    REGISTRY = {
      "claude" => Claude.new,
      "codex" => Base.new(runner_key: "codex"),
      "gemini" => Base.new(runner_key: "gemini"),
      "copilot" => Base.new(runner_key: "copilot")
    }.freeze

    class << self
      def for_runner(runner_key)
        REGISTRY[runner_key.to_s]
      end
    end
  end
end
