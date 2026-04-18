# frozen_string_literal: true

module Scaling
  module Orchestrators
    # Value objects returned by orchestrator adapters. These types form the
    # stable boundary between scaling policy and orchestrator internals.
    module Data
      # Current status of a service within the orchestrator.
      #
      # @!attribute service [String] Service name.
      # @!attribute current_replicas [Integer] Running replica count.
      # @!attribute desired_replicas [Integer] Target replica count.
      # @!attribute available_replicas [Integer] Ready/healthy replicas.
      # @!attribute cpu_usage [String, nil] Aggregate CPU usage.
      # @!attribute memory_usage [String, nil] Aggregate memory usage.
      # @!attribute ready [Boolean] Whether the service is fully ready.
      ServiceStatus = ::Data.define(
        :service,
        :current_replicas,
        :desired_replicas,
        :available_replicas,
        :cpu_usage,
        :memory_usage,
        :ready
      )

      # Result of a scaling operation.
      #
      # @!attribute service [String] Service name.
      # @!attribute previous_replicas [Integer] Replica count before scaling.
      # @!attribute desired_replicas [Integer] Requested replica count.
      # @!attribute accepted [Boolean] Whether the orchestrator accepted the request.
      # @!attribute message [String, nil] Human-readable status message.
      ScaleResult = ::Data.define(
        :service,
        :previous_replicas,
        :desired_replicas,
        :accepted,
        :message
      )

      # Result of a resource limit update.
      #
      # @!attribute service [String] Service name.
      # @!attribute cpu_limit [String, nil] Applied CPU limit.
      # @!attribute memory_limit [String, nil] Applied memory limit.
      # @!attribute accepted [Boolean] Whether the update was accepted.
      # @!attribute message [String, nil] Human-readable status message.
      ResourceUpdateResult = ::Data.define(
        :service,
        :cpu_limit,
        :memory_limit,
        :accepted,
        :message
      )
    end
  end
end
