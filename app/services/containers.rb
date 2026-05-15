# frozen_string_literal: true

module Containers
  class << self
    def backend
      Rails.application.config.x.container_backend || Backends::Resolver.for(
        ENV.fetch("CONTAINER_BACKEND", "local").to_sym
      )
    end

    # Resolves the backend that owns a given container host.
    # Falls back to the process-global default when host is nil or matches the current backend.
    def backend_for(host)
      return backend if host.blank?

      Backends::Resolver.for(host.to_sym)
    rescue Backends::Resolver::UnknownBackendError
      backend
    end
  end
end
