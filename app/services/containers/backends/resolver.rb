# frozen_string_literal: true

module Containers
  module Backends
    class Resolver
      UnknownBackendError = Class.new(StandardError)

      class << self
        def register(backend_type, factory)
          validate_factory!(factory)
          registry[backend_type.to_sym] = factory
        end

        def reset!(backend_type = nil)
          if backend_type.nil?
            registry.clear
          else
            registry.delete(backend_type.to_sym)
          end
        end

        def for(backend_type)
          factory = registry[backend_type.to_sym] or
            raise UnknownBackendError, "No container backend registered for #{backend_type.inspect}"

          factory.call
        end

        private

        def registry
          @registry ||= {}
        end

        def validate_factory!(factory)
          return if factory.respond_to?(:call)

          raise ArgumentError, "Factory must respond to #call (got #{factory.class})"
        end
      end
    end
  end
end
