# frozen_string_literal: true

module Containers
  class HostReadiness
    CACHE_TTL = 30.seconds
    CACHE_VERSION = "v1"
    SUPPORTED_AGENT_ARCHITECTURES = %w[amd64 arm64].freeze

    Check = Struct.new(:name, :healthy, :details, :remediation_hint, keyword_init: true) do
      def healthy?
        healthy == true
      end

      def to_h
        {
          name: name,
          healthy: healthy?,
          details: details,
          remediation_hint: remediation_hint
        }
      end
    end

    Requirements = Struct.new(
      :host_paths_required,
      :subscription_auth_source,
      :service_containers_required,
      :required_network,
      :proxy_auth_required,
      keyword_init: true
    ) do
      def host_paths_required?
        host_paths_required == true
      end

      def service_containers_required?
        service_containers_required == true
      end

      def proxy_auth_required?
        proxy_auth_required == true
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(backends: Containers.all_backends, cache: Rails.cache, image: Containers::Provision::DEFAULTS[:image],
      now: Time.current, requirements: nil, force_refresh: false)
      @backends = Array(backends)
      @cache = cache
      @image = image
      @now = now
      @requirements = requirements
      @force_refresh = force_refresh
    end

    def call
      backends.index_with { |backend| readiness_for(backend) }
    end

    private

    attr_reader :backends, :cache, :force_refresh, :image, :now, :requirements

    def readiness_for(backend)
      payload = if force_refresh
        build_base_payload(backend)
      else
        cache.fetch(cache_key(backend), expires_in: CACHE_TTL) { build_base_payload(backend) }
      end
      finalize_payload(payload.deep_dup, backend)
    end

    def build_base_payload(backend)
      checks = []
      checks << ping_check(backend)
      checks << daemon_info_check(backend)
      checks << architecture_check(backend, checks.last.details)
      checks << network_check(backend, NetworkPolicy::NETWORK_NAME)
      checks << network_check(backend, NetworkPolicy::INFRA_NETWORK_NAME)
      checks << image_check(backend)
      checks << proxy_callback_check(backend)

      failing_check = checks.find { |check| !check.healthy? }

      {
        host: backend.identifier,
        healthy: failing_check.nil?,
        checked_at: now,
        failing_check: failing_check&.name,
        remediation_hint: failing_check&.remediation_hint,
        checks: checks.map(&:to_h)
      }
    rescue StandardError => error
      check = failure_check(name: "docker_ping", error: error, remediation_hint: docker_ping_hint(backend))
      {
        host: backend.identifier,
        healthy: false,
        checked_at: now,
        failing_check: check.name,
        remediation_hint: check.remediation_hint,
        checks: [ check.to_h ]
      }
    ensure
      log_payload(backend, failing_check || check)
    end

    def finalize_payload(payload, backend)
      payload[:capability_compatibility] = selected_run_compatibility(payload, backend)
      compatibility = payload[:capability_compatibility]
      return payload if compatibility[:eligible]

      payload[:healthy] = false
      payload[:failing_check] ||= compatibility[:check]
      payload[:remediation_hint] ||= compatibility[:remediation_hint]
      payload
    end

    def ping_check(backend)
      backend.ping
      healthy_check(name: "docker_ping", details: { backend: backend.identifier })
    rescue StandardError => error
      name = tls_error?(error) && backend.remote? ? "docker_tls" : "docker_ping"
      failure_check(name: name, error: error, remediation_hint: tls_error?(error) ? tls_hint(backend) : docker_ping_hint(backend))
    end

    def daemon_info_check(backend)
      details = backend.system_info
      healthy_check(name: "docker_daemon_info", details: details)
    rescue StandardError => error
      name = tls_error?(error) && backend.remote? ? "docker_tls" : "docker_daemon_info"
      failure_check(name: name, error: error, remediation_hint: tls_error?(error) ? tls_hint(backend) : daemon_info_hint(backend))
    end

    def architecture_check(_backend, daemon_info)
      architecture = normalize_architecture(daemon_info&.[]("Architecture"))
      # Backends that aggregate multiple nodes (e.g. Swarm) may not report a
      # single Architecture. Treat an undeterminable architecture as compatible
      # rather than false-negating those hosts with a misleading hint.
      compatible = architecture.nil? || SUPPORTED_AGENT_ARCHITECTURES.include?(architecture)
      check = Check.new(
        name: "docker_architecture",
        healthy: compatible,
        details: {
          architecture: architecture,
          compatible: compatible,
          image: image
        },
        remediation_hint: compatible ? nil : "Publish #{image} for #{architecture || 'this architecture'} or select a compatible Docker host."
      )
      check
    end

    def network_check(backend, network_name)
      backend.get_network(network_name)
      healthy_check(name: "docker_network:#{network_name}", details: { network: network_name })
    rescue Docker::Error::NotFoundError => error
      failure_check(
        name: "docker_network:#{network_name}",
        error: error,
        remediation_hint: "Create the #{network_name} Docker network on #{backend.identifier}."
      )
    rescue StandardError => error
      failure_check(
        name: "docker_network:#{network_name}",
        error: error,
        remediation_hint: "Docker network #{network_name} is unreachable on #{backend.identifier} (#{error.class})."
      )
    end

    def image_check(backend)
      backend.get_image(image)
      healthy_check(name: "docker_image", details: { image: image })
    rescue Docker::Error::NotFoundError => error
      failure_check(
        name: "docker_image",
        error: error,
        remediation_hint: "Load or build #{image} on #{backend.identifier} before scheduling runs there."
      )
    rescue StandardError => error
      failure_check(
        name: "docker_image",
        error: error,
        remediation_hint: "Docker image #{image} is unreachable on #{backend.identifier} (#{error.class})."
      )
    end

    def proxy_callback_check(backend)
      return healthy_check(name: "proxy_callback", details: { required: false }) unless backend.remote?

      # Configuration-only validation: resolving the callback URL confirms that
      # PAID_PROXY_EXTERNAL_URL(_HOST) is present and well-formed for this
      # backend. This probe runs on the control plane, so it cannot prove that
      # containers on the remote host can actually reach the URL (a control-plane
      # request would produce false positives when only the control plane has
      # connectivity, and false negatives when only the container network does).
      # Actual reachability is enforced at runtime when the container connects to
      # the proxy; this check only surfaces a missing or malformed callback URL.
      callback_url = Containers::ProxyUrl.resolve(backend:, restricted: true)
      healthy_check(name: "proxy_callback", details: { url: callback_url, validated: "configuration" })
    rescue StandardError => error
      failure_check(
        name: "proxy_callback",
        error: error,
        remediation_hint: "Configure a valid PAID_PROXY_EXTERNAL_URL or PAID_PROXY_EXTERNAL_URL_<HOST> for #{backend.identifier} containers."
      )
    end

    def selected_run_compatibility(payload, backend)
      return compatible_payload unless requirements

      network_name = requirements.required_network.presence ||
        (requirements.service_containers_required? ? NetworkPolicy::INFRA_NETWORK_NAME : nil)
      if network_name && failed_check?(payload, "docker_network:#{network_name}")
        return incompatible_payload(
          check: "selected_run_capability",
          reason: "missing_network",
          message: "Required network #{network_name} is not ready on #{backend.identifier}.",
          remediation_hint: "Create #{network_name} on #{backend.identifier} before placing runs that need it."
        )
      end

      if requirements.host_paths_required? && !backend.supports_host_paths?
        return incompatible_payload(
          check: "selected_run_capability",
          reason: "requires_host_bind_mount",
          message: "#{backend.identifier} does not support host bind mounts.",
          remediation_hint: "Place this run on a host-path-capable backend."
        )
      end

      if requirements.proxy_auth_required? && failed_check?(payload, "proxy_callback")
        return incompatible_payload(
          check: "selected_run_capability",
          reason: "remote_proxy_unreachable",
          message: "Proxy callback is not ready on #{backend.identifier}.",
          remediation_hint: "Fix the host callback URL before placing proxy-auth runs on #{backend.identifier}."
        )
      end

      auth_source = requirements.subscription_auth_source
      if auth_source
        eligibility = Runners::SubscriptionAuthEligibility.call(
          backend: backend,
          auth_source: auth_source,
          proxy_reachable: !failed_check?(payload, "proxy_callback")
        )
        unless eligibility.eligible?
          return incompatible_payload(
            check: "selected_run_capability",
            reason: eligibility.reason,
            message: eligibility.message,
            remediation_hint: eligibility.message
          )
        end
      end

      compatible_payload
    end

    def compatible_payload
      {
        eligible: true,
        check: nil,
        reason: nil,
        message: nil,
        remediation_hint: nil
      }
    end

    def incompatible_payload(check:, reason:, message:, remediation_hint:)
      {
        eligible: false,
        check: check,
        reason: reason,
        message: message,
        remediation_hint: remediation_hint
      }
    end

    def failed_check?(payload, name)
      payload.fetch(:checks).any? { |check| check[:name] == name && check[:healthy] == false }
    end

    def normalize_architecture(value)
      value.to_s.downcase.presence&.yield_self do |architecture|
        case architecture
        when "x86_64" then "amd64"
        when "aarch64" then "arm64"
        else architecture
        end
      end
    end

    def tls_error?(error)
      message = error.message.to_s.downcase
      message.include?("tls") || message.include?("ssl") || message.include?("certificate")
    end

    def healthy_check(name:, details:)
      Check.new(name: name, healthy: true, details: details, remediation_hint: nil)
    end

    def failure_check(name:, error:, remediation_hint:)
      Check.new(
        name: name,
        healthy: false,
        details: {
          error_class: error.class.name,
          error_message: error.message
        },
        remediation_hint: remediation_hint
      )
    end

    def docker_ping_hint(backend)
      "Ensure Docker is running and reachable on #{backend.identifier}."
    end

    def daemon_info_hint(backend)
      "Verify docker info works on #{backend.identifier} and that the daemon is healthy."
    end

    def tls_hint(backend)
      "Verify the TLS client certificate, key, and CA for #{backend.identifier}, then retry the Docker connection."
    end

    def cache_key(backend)
      "containers/host_readiness/#{backend.identifier}/#{image}/#{CACHE_VERSION}"
    end

    def log_payload(backend, failing_check)
      if failing_check&.healthy? == false
        Rails.logger.warn(
          message: "container_manager.host_readiness.failed",
          host: backend.identifier,
          failing_check: failing_check.name,
          remediation_hint: failing_check.remediation_hint
        )
      else
        Rails.logger.info(
          message: "container_manager.host_readiness.ok",
          host: backend.identifier
        )
      end
    end
  end
end
