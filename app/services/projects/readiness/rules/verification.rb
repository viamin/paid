# frozen_string_literal: true

module Projects
  module Readiness
    module Rules
      # Checkout-backed prerequisites for the optional interactive-verification
      # capability. Runtime reachability deliberately stays out of this rule:
      # an unavailable browser or service is an observation about one run, not
      # durable evidence that the repository is unready.
      # @spec PROJECT-READINESS-011
      class Verification
        def self.call(...)
          new(...).call
        end

        def initialize(project:, repo_path:)
          @project = project
          @repo_path = repo_path
        end

        def call
          return [] unless project.verification_enabled?

          [ configuration_gap, start_command_gap, service_gaps ].flatten.compact
        rescue ::Screenshots::ConfigError => error
          [ invalid_configuration_gap(error) ]
        end

        private

        attr_reader :project, :repo_path

        def runtime_plan
          @runtime_plan ||= ::Screenshots::RuntimePlan.call(project:, repo_path:)
        end

        def configuration_gap
          runtime_plan.config
          nil
        end

        def start_command_gap
          return if runtime_plan.start_command_available?

          Gap.new(
            kind: "app_start_command_unavailable",
            description: "Interactive verification needs an applicable application start command.",
            evidence: { framework: runtime_plan.framework, base_url: runtime_plan.base_url }
          )
        end

        def service_gaps
          runtime_plan.config.services.filter_map do |service_name|
            next if configured_service_names.include?(service_name)

            Gap.new(
              kind: "missing_verification_service",
              description: "Interactive verification requires the #{service_name} service to be configured for this project.",
              evidence: { service: service_name }
            )
          end
        end

        def configured_service_names
          @configured_service_names ||= project.service_containers.pluck(:name).to_set
        end

        def invalid_configuration_gap(error)
          Gap.new(
            kind: "verification_configuration_invalid",
            description: "Interactive verification configuration is invalid and must be repaired.",
            evidence: { error: error.message }
          )
        end
      end
    end
  end
end
