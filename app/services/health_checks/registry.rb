# frozen_string_literal: true

module HealthChecks
  # Registry of health check classes.
  # Populated by phases 2–5 as concrete checks are added.
  class Registry
    class << self
      def all
        load_defaults
        @registry.dup.freeze
      end

      def for_scope(scope)
        all.select { |check| check.scope == scope.to_sym }
      end

      def local_for_scope(scope)
        for_scope(scope).reject(&:network?)
      end

      def register(check_class)
        @registry ||= []
        @registry << check_class unless @registry.include?(check_class)
      end

      private

      def load_defaults
        return if @defaults_loaded

        @registry ||= []
        # Phases 2–5 register concrete checks here.
        @defaults_loaded = true
      end
    end
  end
end
