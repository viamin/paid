# frozen_string_literal: true

Rails.application.config.to_prepare do
  resolver = Containers::Backends::Resolver
  resolver.reset!
  resolver.register(:local, -> { Containers::Backends::LocalDocker.new })
  if (remote_backend = Containers::Backends::RemoteDocker.from_env)
    resolver.register(remote_backend.identifier, -> { remote_backend })
    resolver.register(:remote, -> { remote_backend })
  end

  backend_type = ENV.fetch("CONTAINER_BACKEND", "local").to_sym
  Rails.application.config.x.container_backend = resolver.for(backend_type)
end
