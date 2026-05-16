# frozen_string_literal: true

module Containers
  module ProxyUrl
    module_function

    def resolve(backend:, restricted:)
      if backend.remote? && ENV["PAID_PROXY_EXTERNAL_URL"].present?
        return ENV["PAID_PROXY_EXTERNAL_URL"]
      end

      proxy_port = Rails.application.config.x.paid_proxy_port
      proxy_host = restricted ? "paid-proxy" : "web"
      "http://#{proxy_host}:#{proxy_port}"
    end
  end
end
