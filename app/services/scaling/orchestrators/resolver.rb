# frozen_string_literal: true

module Scaling
  module Orchestrators
    # Resolver maps an orchestrator type identifier to its concrete adapter
    # implementation.
    #
    # Implementations register themselves via {.register}. Scaling policy
    # code looks up the adapter via {.for}. When no orchestrator type is
    # specified it defaults to +:docker_compose+, matching the development
    # environment.
    #
    # == Example registration
    #
    #   Scaling::Orchestrators::Resolver.register(
    #     :kubernetes,
    #     -> (config) { KubernetesAdapter.new(**config) }
    #   )
    #
    # Factories are invoked with an optional configuration hash on every
    # resolution call. They MAY cache the returned instance, but the
    # resolver itself is intentionally stateless so that tests can register
    # and clear implementations independently.
    class Resolver
      UnknownOrchestratorError = Class.new(StandardError)

      class << self
        # Registers a factory for an orchestrator type. The factory is a
        # callable (proc/lambda/object responding to +#call+) that accepts
        # a configuration hash and returns an object that includes the
        # {Scaling::Orchestrator} module.
        #
        # @param orchestrator_type [Symbol] e.g. +:kubernetes+, +:docker_compose+, +:ecs+.
        # @param factory [#call] Factory callable.
        # @return [void]
        def register(orchestrator_type, factory)
          validate_factory!(factory)
          registry[orchestrator_type.to_sym] = factory
        end

        # Removes all registered factories. Primarily useful in tests to
        # isolate registration between examples.
        #
        # @param orchestrator_type [Symbol, nil] When nil, clears every
        #   registration.
        # @return [void]
        def reset!(orchestrator_type = nil)
          if orchestrator_type.nil?
            registry.clear
          else
            registry.delete(orchestrator_type.to_sym)
          end
        end

        # @return [Array<Symbol>] Registered orchestrator type identifiers.
        def registered_types
          registry.keys
        end

        # @param orchestrator_type [Symbol]
        # @return [Boolean]
        def registered?(orchestrator_type)
          registry.key?(orchestrator_type.to_sym)
        end

        # Resolves the orchestrator adapter for the given type.
        #
        # @param orchestrator_type [Symbol] e.g. +:kubernetes+, +:docker_compose+.
        # @param config [Hash] Configuration passed to the factory.
        # @return [Object] An instance including {Scaling::Orchestrator}.
        def for(orchestrator_type, **config)
          factory = registry[orchestrator_type.to_sym] or
            raise UnknownOrchestratorError,
              "No orchestrator registered for type #{orchestrator_type.inspect}"

          factory.call(config)
        end

        private

        def registry
          @registry ||= {}
        end

        def validate_factory!(factory)
          return if factory.respond_to?(:call)

          raise ArgumentError,
            "Factory must respond to #call (got #{factory.class})"
        end
      end
    end
  end
end
