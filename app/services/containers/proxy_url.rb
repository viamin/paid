# frozen_string_literal: true

require "uri"

module Containers
  module ProxyUrl
    module_function

    def resolve(backend:, restricted:)
      if backend.remote?
        external_url = external_url_for(backend)
        raise ArgumentError, "PAID_PROXY_EXTERNAL_URL or PAID_PROXY_EXTERNAL_URL_<HOST> is required when CONTAINER_BACKEND is remote" if external_url.blank?

        return validate_external_url!(external_url)
      end

      proxy_port = Rails.application.config.x.paid_proxy_port
      proxy_host = restricted ? "paid-proxy" : "web"
      "http://#{proxy_host}:#{proxy_port}"
    end

    def validate_external_url!(url)
      uri = URI.parse(url)
      raise ArgumentError, "PAID_PROXY_EXTERNAL_URL must include scheme and host" if uri.scheme.blank? || uri.host.blank?
      raise ArgumentError, "PAID_PROXY_EXTERNAL_URL must use http or https" unless uri.scheme.in?(%w[http https])
      raise ArgumentError, "PAID_PROXY_EXTERNAL_URL port must be between 1 and 65535" unless uri.port.between?(1, 65_535)

      url
    rescue URI::InvalidURIError => e
      raise ArgumentError, "Invalid PAID_PROXY_EXTERNAL_URL: #{e.message}"
    end

    def external_url_for(backend)
      specific_key = "PAID_PROXY_EXTERNAL_URL_#{backend.identifier.to_s.upcase.tr('-', '_')}"
      ENV[specific_key].presence || ENV["PAID_PROXY_EXTERNAL_URL"].presence
    end
  end
end
