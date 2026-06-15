# frozen_string_literal: true

module Containers
  LOCAL_BACKEND_KEY = :local
  REMOTE_BACKEND_KEY = :remote
  CONTAINER_NOT_RUNNING_PATTERN = /is not running|No such container/i

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
      return local_backend || resolved_backend if host.blank?
      return resolved_backend if host.to_s == resolved_backend.identifier
      return resolved_backend if resolved_backend.owns_host?(host)

      Backends::Resolver.for(host.to_sym)
    end

    def all_backends
      active_backend = backend
      backends = { active_backend.identifier => active_backend }

      cleanup_backend_keys(active_backend).each do |backend_type|
        candidate = resolve_optional_backend(backend_type)
        next unless candidate

        backends[candidate.identifier] = candidate
      end
      backends.values
    end

    private

    def cleanup_backend_keys(active_backend)
      return [] if active_backend.identifier.to_sym == :swarm

      keys = []
      keys << LOCAL_BACKEND_KEY if active_backend.remote?
      keys << REMOTE_BACKEND_KEY if active_backend.identifier.to_sym == LOCAL_BACKEND_KEY
      keys
    end

    def local_backend
      resolve_optional_backend(LOCAL_BACKEND_KEY)
    end

    def remote_backend
      resolve_optional_backend(REMOTE_BACKEND_KEY)
    end

    def resolve_optional_backend(backend_type)
      return unless Backends::Resolver.backend_types.include?(backend_type)

      Backends::Resolver.for(backend_type)
    end
  end
end
