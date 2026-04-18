# frozen_string_literal: true

module Scaling
  # Orchestrator defines the capabilities the scaling system needs from a
  # container orchestrator (Kubernetes, Docker Compose, ECS, ...) to
  # translate scaling decisions into infrastructure actions.
  #
  # == Contract
  #
  # Implementations of this module MUST:
  #
  # - Accept the exact keyword arguments declared by each method.
  # - Return values of the documented {Scaling::Orchestrators::Data} type,
  #   or +nil+ where explicitly allowed.
  # - Raise a subclass of {OrchestratorError} for expected transient or
  #   permanent orchestrator failures (authentication, API errors, resource
  #   not found). Unexpected errors may propagate, but callers should be
  #   able to distinguish "orchestrator said no" from "code blew up" via
  #   the error hierarchy supplied by the implementation.
  # - Be idempotent for write operations when the underlying API is
  #   idempotent (e.g. scaling to the current replica count succeeds
  #   without error).
  #
  # == Usage
  #
  #   orchestrator = Scaling::Orchestrators::Resolver.for(:kubernetes)
  #   status = orchestrator.current_status(service: "agent-worker")
  #   orchestrator.scale(service: "agent-worker", desired_replicas: 5)
  #
  # == Method groups
  #
  # * Read: {#current_status}
  # * Write: {#scale}, {#set_resource_limits}
  # * Health: {#healthy?}
  module Orchestrator
    class OrchestratorError < StandardError; end

    # Returns the current scaling status of a service.
    #
    # @param service [String] Service name or identifier recognized by
    #   the orchestrator (e.g. Deployment name in Kubernetes, service
    #   name in Docker Compose).
    # @return [Scaling::Orchestrators::Data::ServiceStatus]
    # @raise [OrchestratorError] When the service cannot be located or
    #   access is denied.
    def current_status(service:)
      raise NotImplementedError, not_implemented_message(__method__)
    end

    # Scales a service to the desired replica count.
    #
    # Orchestrators that do not support exact replica counts (e.g. those
    # using autoscaling ranges) SHOULD adjust the autoscaler target and
    # document the behavior.
    #
    # @param service [String] Service name or identifier.
    # @param desired_replicas [Integer] Target number of replicas.
    # @return [Scaling::Orchestrators::Data::ScaleResult]
    # @raise [OrchestratorError] When the scaling action is rejected.
    def scale(service:, desired_replicas:)
      raise NotImplementedError, not_implemented_message(__method__)
    end

    # Updates resource limits (CPU, memory) for a service.
    #
    # @param service [String] Service name or identifier.
    # @param cpu_limit [String, nil] CPU limit (e.g. "500m", "2").
    # @param memory_limit [String, nil] Memory limit (e.g. "512Mi", "2Gi").
    # @return [Scaling::Orchestrators::Data::ResourceUpdateResult]
    # @raise [OrchestratorError] When the update is rejected.
    def set_resource_limits(service:, cpu_limit: nil, memory_limit: nil)
      raise NotImplementedError, not_implemented_message(__method__)
    end

    # Returns whether the orchestrator connection is healthy.
    #
    # @return [Boolean]
    def healthy?
      raise NotImplementedError, not_implemented_message(__method__)
    end

    private

    def not_implemented_message(method_name)
      "#{self.class} must implement ##{method_name}"
    end
  end
end
