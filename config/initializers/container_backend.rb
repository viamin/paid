# frozen_string_literal: true

Rails.application.config.to_prepare do
  resolver = Containers::Backends::Resolver
  resolver.reset!

  backend_type = ENV.fetch("CONTAINER_BACKEND", "local").to_sym

  remote_backends = if backend_type == :multi
    registry = Containers::HostRegistry.load
    registry.hosts.each do |host|
      resolver.register(host.identifier, -> { host.backend })
      resolver.register(:local, -> { host.backend }) unless host.backend.remote?
    end
    if registry.default_host.blank?
      raise ArgumentError, "CONTAINER_BACKENDS_CONFIG must define at least one host under 'multi' backend mode"
    end
    Rails.application.config.x.container_backend = resolver.for(registry.default_host.to_sym)
    registry.hosts.filter_map { |host| host.backend if host.backend.remote? }
  else
    resolver.register(:local, -> { Containers::Backends::LocalDocker.new })
    if (remote_backend = Containers::Backends::RemoteDocker.from_env)
      resolver.register(remote_backend.identifier, -> { remote_backend })
      resolver.register(:remote, -> { remote_backend })
    end
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
    active_backend = resolver.for(backend_type)
    Rails.application.config.x.container_backend = active_backend
    active_backend.remote? ? [ active_backend ] : []
  end

  Containers.instance_variable_set(:@host_registry, nil)

  if remote_backends.any? { |backend| Containers::ProxyUrl.external_url_for(backend).blank? }
    Rails.logger.warn(
      "Remote Docker backend is active but PAID_PROXY_EXTERNAL_URL or PAID_PROXY_EXTERNAL_URL_<HOST> is not set; remote containers will be unable to reach the secrets proxy"
    )
  end
end
