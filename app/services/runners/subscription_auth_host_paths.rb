# frozen_string_literal: true

module Runners
  # RDR-041 / #2959 scheduler-facing helper that answers the only question the
  # scheduler/readiness layer needs about a runner's resolved auth mode:
  # does this (runner_key, auth_mode) combination require a Docker host bind
  # mount?
  #
  # The answer is the bridge between the auth-source vocabulary
  # (`:managed`, `:host_forwarded`, `:api_key_proxy`) and the backend capability
  # (`backend.supports_host_paths?`). Eligibility (Runners::SubscriptionAuthEligibility)
  # still owns the per-backend decision; this helper just gives the scheduler a
  # cheap, deterministic predicate so it can plan routing without booting an
  # eligibility result.
  #
  # Truth table for the four RDR-041 acceptance criteria:
  #
  #   Claude managed          -> false  (env-token / native-file materializer is remote-safe)
  #   Claude host_forwarded   -> true   (host ~/.claude bind mount)
  #   Codex host_forwarded    -> true   (host ~/.codex bind mount; remote-safe materializer pending #2962)
  #   api_key_proxy           -> false  (proxy config only; no host filesystem)
  #
  # Defaults to `true` for unknown runner_keys so an unrecognised subscription
  # provider stays on a host-path-capable backend instead of being silently
  # green-lit for remote placement. The matching eligibility reason
  # (`:provider_materializer_missing`) catches the same case on the eligibility
  # side.
  class SubscriptionAuthHostPaths
    AUTH_MODES = %i[managed host_forwarded api_key_proxy none].freeze

    class << self
      # Returns true when a (runner_key, auth_mode) combination requires a
      # Docker host bind mount. Both arguments accept strings or symbols so
      # callers can pass values straight from CLI args or persisted rows.
      def requires?(runner_key:, auth_mode:)
        runner = normalize_runner_key(runner_key)
        mode = normalize_auth_mode(auth_mode)

        return false if mode == :api_key_proxy
        return true if mode == :host_forwarded
        return false if mode == :none

        managed_requires_host_paths?(runner)
      end

      # Convenience for the AuthSource struct already produced by
      # SubscriptionAuthEligibility detection. Returns false for `none` rather
      # than raising, because a missing auth source is "no host paths needed"
      # in scheduler terms (the run cannot authenticate on either host-path
      # or remote backends, and that is a separate rejection surfaced by
      # eligibility).
      def requires_for?(auth_source)
        return false unless auth_source

        requires?(
          runner_key: auth_source.respond_to?(:runner_key) ? auth_source.runner_key : nil,
          auth_mode: auth_source.respond_to?(:auth_mode) ? auth_source.auth_mode : nil
        )
      end

      private

      def managed_requires_host_paths?(runner_key)
        materializer = SubscriptionAuthMaterializers.for_runner(runner_key)
        return true unless materializer

        materializer.requires_host_paths?
      end

      def normalize_runner_key(runner_key)
        return nil if runner_key.nil?

        runner_key.to_s.strip.downcase.presence
      end

      def normalize_auth_mode(auth_mode)
        return :none if auth_mode.nil?

        symbol = auth_mode.to_sym
        return :none unless AUTH_MODES.include?(symbol)

        symbol
      end
    end
  end
end
