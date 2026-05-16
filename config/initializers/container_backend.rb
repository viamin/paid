# frozen_string_literal: true

Rails.application.config.to_prepare do
  resolver = Containers::Backends::Resolver
  resolver.reset!(:local)
  resolver.reset!(:swarm)
  resolver.register(:local, -> { Containers::Backends::LocalDocker.new })
  resolver.register(:swarm, -> {
    Containers::Backends::Swarm.new(
      manager_host: ENV.fetch("SWARM_MANAGER_HOST", ENV.fetch("DOCKER_HOST", "unix:///var/run/docker.sock")),
      connection_options: Containers::Backends::Swarm.connection_options_from_env,
      placement_constraints: ENV["SWARM_PLACEMENT_CONSTRAINTS"],
      placement_preferences: ENV["SWARM_PLACEMENT_PREFERENCES"],
      node_port: Integer(ENV.fetch("SWARM_NODE_DOCKER_PORT", Containers::Backends::Swarm::DEFAULT_NODE_PORT)),
      node_scheme: ENV.fetch("SWARM_NODE_DOCKER_SCHEME", Containers::Backends::Swarm::DEFAULT_NODE_SCHEME)
    )
  })

  backend_type = ENV.fetch("CONTAINER_BACKEND", "local").to_sym
  Rails.application.config.x.container_backend = resolver.for(backend_type)
end
