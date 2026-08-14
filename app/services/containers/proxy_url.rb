# frozen_string_literal: true

require "uri"

module Containers
  # Resolves the secrets-proxy URL the agent container should reach.
  #
  # The URL depends on the container's networking policy:
  #
  # - Restricted containers (Docker `paid_agent` bridge, in-container firewall)
  #   reach the proxy by its Docker DNS hostname (`paid-proxy`) so the iptables
  #   rules can pin egress to that host.
  # - Unrestricted containers (Docker `paid_internal`) reach the proxy by its
  #   `web` service hostname because they are not pinned by firewall rules.
  # - Remote backends always use the configured external proxy URL because
  #   the in-cluster Docker DNS names are unreachable across hosts.
  #
  # Callers pass either a +policy:+ object (the provider-neutral abstraction
  # for restricted vs. unrestricted networking — preferred) or a +restricted:+
  # boolean (legacy callers). The two parameters are mutually exclusive.
  module ProxyUrl
    module_function

    # @param backend [Containers::Backends::Base]
    # @param policy [#restricted?] provider-neutral networking policy (RDR-054)
    # @param restricted [Boolean, nil] legacy boolean form. Ignored when
    #   +policy+ is supplied; required when +policy+ is nil.
    # @return [String]
    # @spec CONTAINER-RUNTIME-017
    # @spec CONTAINER-RUNTIME-018
    def resolve(backend:, policy: nil, restricted: nil)
      effective_restricted = if policy
        policy.restricted?
      else
        raise ArgumentError, "Containers::ProxyUrl.resolve requires either policy: or restricted:" if restricted.nil?

        restricted
      end

      if backend.remote?
        external_url = external_url_for(backend)
        raise ArgumentError, "PAID_PROXY_EXTERNAL_URL or PAID_PROXY_EXTERNAL_URL_<HOST> is required when CONTAINER_BACKEND is remote" if external_url.blank?

        return validate_external_url!(external_url)
      end

      proxy_port = Rails.application.config.x.paid_proxy_port
      proxy_host = effective_restricted ? "paid-proxy" : "web"
      "http://#{proxy_host}:#{proxy_port}"
    end

    def validate_external_url!(url)
      validate_external_url_from!(url, source: "PAID_PROXY_EXTERNAL_URL")
    end

    def validate_external_url_from!(url, source:)
      uri = URI.parse(url)
      raise ArgumentError, "#{source} must include scheme and host" if uri.scheme.blank? || uri.host.blank?
      raise ArgumentError, "#{source} must use http or https" unless uri.scheme.in?(%w[http https])
      raise ArgumentError, "#{source} port must be between 1 and 65535" unless uri.port.between?(1, 65_535)

      url
    rescue URI::InvalidURIError => e
      raise ArgumentError, "Invalid #{source}: #{e.message}"
    end

    def external_url_for(backend)
      if backend.respond_to?(:proxy_external_url) && backend.proxy_external_url.present?
        return validate_external_url_from!(
          backend.proxy_external_url,
          source: "proxy_external_url for backend #{backend.identifier.inspect}"
        )
      end

      specific_key = "PAID_PROXY_EXTERNAL_URL_#{env_key_suffix(backend.identifier)}"
      ENV[specific_key].presence || ENV["PAID_PROXY_EXTERNAL_URL"].presence
    end

    def env_key_suffix(identifier)
      identifier.to_s.upcase.gsub(/[^A-Z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end
  end
end
