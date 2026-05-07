# frozen_string_literal: true

Rails.application.config.to_prepare do
  resolver = Scaling::Orchestrators::Resolver

  {
    kubernetes: Scaling::Orchestrators::KubernetesAdapter,
    docker_compose: Scaling::Orchestrators::DockerComposeAdapter,
    docker_swarm: Scaling::Orchestrators::DockerSwarmAdapter,
    ecs: Scaling::Orchestrators::EcsAdapter
  }.each do |type, adapter_class|
    resolver.register(type, ->(config) { adapter_class.new(**config) })
  end
end
