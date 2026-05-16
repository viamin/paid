# frozen_string_literal: true

module Containers
  class << self
    def backend
      Rails.application.config.x.container_backend || Backends::Resolver.for(
        ENV.fetch("CONTAINER_BACKEND", "local").to_sym
      )
    end

    # Resolves the backend that owns a given container host.
    # Reuses the process-global backend when the host is blank or already
    # matches the active backend's identifier.
    def backend_for(host)
      resolved_backend = backend
      return resolved_backend if host.blank? || host.to_s == resolved_backend.identifier
      return resolved_backend if resolved_backend.owns_host?(host)

      Backends::Resolver.for(host.to_sym)
    end

    def all_backends
      active_backend = backend
      backends = { active_backend.identifier => active_backend }

      Backends::Resolver.backend_types.each do |backend_type|
        candidate = Backends::Resolver.for(backend_type)
        backends[candidate.identifier] = candidate
      end

      backends.values
    end

    def remote_backend_active?
      backend.remote?
    end
  end
end
