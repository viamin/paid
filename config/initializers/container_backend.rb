# frozen_string_literal: true

Rails.application.config.to_prepare do
  resolver = Containers::Backends::Resolver
  resolver.reset!
  resolver.register(:local, -> { Containers::Backends::LocalDocker.new })

  backend_type = ENV.fetch("CONTAINER_BACKEND", "local").to_sym
  Rails.application.config.x.container_backend = resolver.for(backend_type)
end
