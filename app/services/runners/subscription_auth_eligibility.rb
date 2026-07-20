# frozen_string_literal: true

module Runners
  # RDR-041 subscription auth host eligibility contract, wired into RDR-048 host
  # selection and readiness (#2963).
  #
  # Answers a single question for the scheduler/readiness layer: given a Docker
  # backend's capabilities and a subscription runner's resolved auth source, can
  # this run authenticate on that backend? When the answer is no, it returns a
  # named rejection reason that is safe to surface in the queue/readiness UI
  # without exposing secrets.
  #
  # The contract (RDR-041, "RDR-048 Host Eligibility Contract"):
  #
  #   if runner uses managed RunnerCredential and materializer.remote_safe?
  #     local and remote Docker are eligible
  #   else if runner uses host-forwarded subscription auth
  #     only backends with supports_host_paths? are eligible
  #   else if runner uses API-key/proxy auth
  #     any backend with proxy/network readiness is eligible
  #   else
  #     reject with "runner is not authenticated"
  #
  # Named rejection reasons surfaced to operators:
  #
  #   requires_host_bind_mount     host-forwarded subscription auth on a backend
  #                                that cannot mount host paths (remote Docker/Swarm)
  #   managed_auth_missing         subscription runner has no managed credential
  #                                and no host-forwarded fallback for remote placement
  #   provider_materializer_missing managed credential exists but the provider has
  #                                no remote-safe materializer registered
  #   credential_expired           managed credential is expired or revoked
  #   credential_refresh_failed    managed credential refresh failed before the run
  #   remote_proxy_unreachable     API-key/proxy auth on a backend whose proxy/
  #                                network readiness check fails
  #   not_authenticated            subscription runner has no resolvable auth source
  #
  # All messages are constructed from non-secret context (runner key, backend
  # identifier, reason). They never include tokens, file contents, or credential
  # payloads.
  class SubscriptionAuthEligibility
    # Description of the auth source resolved for a single subscription runner.
    # The provision layer builds one of these per runner from its existing
    # detection helpers; the eligibility service stays pure and testable.
    AuthSource = Struct.new(
      :runner_key,                    # "claude", "codex", "gemini", "copilot"
      :auth_mode,                     # :managed, :host_forwarded, :api_key_proxy, :none
      :credential_state,              # :active, :expired, :revoked, :refresh_failed (managed only)
      keyword_init: true
    ) do
      def managed? = auth_mode == :managed
      def host_forwarded? = auth_mode == :host_forwarded
      def api_key_proxy? = auth_mode == :api_key_proxy
      def none? = auth_mode.nil? || auth_mode == :none
    end

    Result = Struct.new(
      :eligible,          # Boolean
      :reason,            # Symbol from REASONS, or nil when eligible
      :runner_key,        # String
      :auth_mode,         # Symbol
      :message,           # Operator-safe human-readable explanation
      keyword_init: true
    ) do
      def eligible? = eligible == true
      def ineligible? = eligible == false
    end

    REASONS = %i[
      requires_host_bind_mount
      managed_auth_missing
      provider_materializer_missing
      credential_expired
      credential_refresh_failed
      remote_proxy_unreachable
      not_authenticated
    ].freeze

    MANAGED_FAILURE_STATES = %i[expired revoked refresh_failed].freeze

    class << self
      def call(backend:, auth_source:, proxy_reachable: true)
        new(backend: backend, auth_source: auth_source, proxy_reachable: proxy_reachable).call
      end

      # Convenience for callers that want to assert no auth is needed at all
      # (e.g. a runner that does not use subscription auth). Always eligible.
      def eligible_for_non_subscription(backend:)
        Result.new(eligible: true, reason: nil, runner_key: nil, auth_mode: :none,
          message: "Runner does not require subscription auth on #{backend_identifier(backend)}.")
      end

      def backend_identifier(backend)
        backend.respond_to?(:identifier) ? backend.identifier : backend.to_s
      end
    end

    def initialize(backend:, auth_source:, proxy_reachable: true)
      @backend = backend
      @auth_source = auth_source
      @proxy_reachable = proxy_reachable
    end

    def call
      return not_authenticated if auth_source.none?

      case auth_source.auth_mode
      when :managed then evaluate_managed
      when :host_forwarded then evaluate_host_forwarded
      when :api_key_proxy then evaluate_api_key_proxy
      else not_authenticated
      end
    end

    private

    attr_reader :backend, :auth_source, :proxy_reachable

    def evaluate_managed
      return credential_failure if managed_credential_failed?

      materializer = SubscriptionAuthMaterializers.for_runner(auth_source.runner_key)
      if materializer&.remote_safe?
        eligible(auth_mode: :managed,
          message: "Managed #{auth_source.runner_key} credential is remote-safe " \
                   "on #{backend_identifier}.")
      elsif host_paths?
        # No remote-safe materializer, but the backend can mount host paths, so
        # a host-forwarded fallback (resolved separately) keeps the run local.
        eligible(auth_mode: :managed,
          message: "Managed #{auth_source.runner_key} credential is eligible on " \
                   "host-path-capable backend #{backend_identifier}.")
      else
        ineligible(:provider_materializer_missing,
          message: "#{label} has a managed credential but no remote-safe " \
                   "materializer is registered for #{backend_identifier}. " \
                   "Use a host-path-capable backend or wait for the provider adapter.")
      end
    end

    def evaluate_host_forwarded
      return eligible(auth_mode: :host_forwarded,
        message: "Host-forwarded #{auth_source.runner_key} subscription auth is " \
                 "eligible on host-path-capable backend #{backend_identifier}.") if host_paths?

      ineligible(:requires_host_bind_mount,
        message: "#{label} uses host-forwarded subscription auth, but backend " \
                 "#{backend_identifier} does not support host bind mounts." \
                 "#{managed_fallback_hint}")
    end

    # Provider-aware guidance appended to host-forwarded rejections. Only suggest
    # the managed credential flow when the provider actually has a remote-safe
    # materializer; otherwise direct the operator to a host-path-capable backend.
    def managed_fallback_hint
      if Runners::SubscriptionAuthMaterializers.remote_safe?(auth_source.runner_key)
        " Configure a managed #{auth_source.runner_key} credential to run on remote Docker."
      else
        " Use a host-path-capable backend, or wait for the #{auth_source.runner_key} managed-auth adapter."
      end
    end

    def evaluate_api_key_proxy
      return eligible(auth_mode: :api_key_proxy,
        message: "#{label} API-key/proxy auth is eligible on #{backend_identifier} " \
                 "when the proxy is reachable.") if proxy_reachable

      ineligible(:remote_proxy_unreachable,
        message: "#{label} API-key/proxy auth requires a reachable Paid proxy, but " \
                 "backend #{backend_identifier} cannot reach the configured proxy URL.")
    end

    # auth_mode :none means no auth source resolved for this subscription runner.
    # On any backend the actionable fix is to add a managed credential (or a
    # host-forwarded fallback on a host-path-capable backend), so we surface
    # `managed_auth_missing` rather than a generic "not authenticated".
    def not_authenticated
      ineligible(:managed_auth_missing,
        message: "#{label} has no resolvable subscription auth source for " \
                 "#{backend_identifier}. Configure a managed #{auth_source.runner_key} " \
                 "credential or host-forwarded auth.")
    end

    def credential_failure
      state = auth_source.credential_state
      reason = state == :refresh_failed ? :credential_refresh_failed : :credential_expired
      ineligible(reason,
        message: "#{label} managed credential is #{state} and cannot authenticate " \
                 "on #{backend_identifier}.")
    end

    def managed_credential_failed?
      MANAGED_FAILURE_STATES.include?(auth_source.credential_state)
    end

    def eligible(auth_mode:, message:)
      Result.new(eligible: true, reason: nil, runner_key: auth_source.runner_key,
        auth_mode: auth_mode, message: message)
    end

    def ineligible(reason, message:)
      Result.new(eligible: false, reason: reason, runner_key: auth_source.runner_key,
        auth_mode: auth_source.auth_mode, message: message)
    end

    def host_paths?
      backend.respond_to?(:supports_host_paths?) ? backend.supports_host_paths? : true
    end

    def backend_identifier
      self.class.backend_identifier(backend)
    end

    def label
      auth_source.runner_key.present? ? auth_source.runner_key.capitalize : "Runner"
    end
  end
end
