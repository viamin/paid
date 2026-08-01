# frozen_string_literal: true

module HealthChecks
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

        register(HealthChecks::Checks::Project::AutoMergeWithoutOwner)
        register(HealthChecks::Checks::Project::ReviewWithoutBot)
        register(HealthChecks::Checks::Project::EmptyAllowlist)
        register(HealthChecks::Checks::Project::MissingGitHubCredential)
        register(HealthChecks::Checks::Project::SensitiveDataFreeModel)
        register(HealthChecks::Checks::Runner::InactiveModel)
        register(HealthChecks::Checks::Runner::ExpiredModel)
        register(HealthChecks::Checks::Runner::BelowQualityBarModel)
        register(HealthChecks::Checks::Runner::IncompatibleModel)
        register(HealthChecks::Checks::Runner::MissingRunnerCredentials)
        register(HealthChecks::Checks::Runner::SupersededModel)
        register(HealthChecks::Checks::User::NoAgentRunners)
        register(HealthChecks::Checks::User::InvalidFallbackChain)
        register(HealthChecks::Checks::User::MissingDefaultRunner)
        @defaults_loaded = true
      end
    end
  end
end
