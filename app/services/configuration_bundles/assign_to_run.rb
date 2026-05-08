# frozen_string_literal: true

require "digest"

module ConfigurationBundles
  class AssignToRun
    include BundleFingerprinting

    INVALID_EXPERIMENT_VALUE = Object.new

    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      selection = optimizer_selection
      definition = bundle_definition(selection&.variant_by_experiment_id)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(definition))

      bundle = find_or_create_bundle(fingerprint:, definition:)
      agent_run.update!(
        configuration_bundle: bundle,
        configuration_bundle_selection_mode: selection&.selection_mode || "exploitative",
        configuration_bundle_selection_context: selection&.selection_context || default_selection_context
      )
      bundle
    end

    private

    def find_or_create_bundle(fingerprint:, definition:)
      existing_bundle = bundle_scope.find_by(fingerprint: fingerprint)
      return existing_bundle if existing_bundle&.definition == definition
      return existing_bundle.tap { |bundle| bundle.update!(definition: definition) } if existing_bundle

      account.with_lock do
        bundle_scope.find_by(fingerprint: fingerprint) || create_runtime_bundle(fingerprint:, definition:)
      end
    rescue ActiveRecord::RecordNotUnique
      bundle_scope.find_by!(fingerprint: fingerprint)
    end

    def create_runtime_bundle(fingerprint:, definition:)
      ConfigurationBundle.create!(
        account: account,
        name: "Runtime Bundle #{fingerprint.first(12)}",
        version: next_runtime_bundle_version,
        status: "active",
        strategy: "runtime_snapshot",
        strategy_params: {},
        context: {},
        fingerprint: fingerprint,
        definition: definition
      )
    end

    def next_runtime_bundle_version
      ConfigurationBundle.where(account: account, project_id: nil).maximum(:version).to_i + 1
    end

    def bundle_scope
      ConfigurationBundle.where(account: account)
    end

    def account
      agent_run.project.account
    end

    def bundle_definition(selected_variants = nil)
      canonicalize(
        {
          schema_version: 1,
          goal: agent_run.goal,
          agent_type: agent_run.agent_type,
          provider_id: agent_run.provider_id,
          prompt_version_id: agent_run.prompt_version_id,
          custom_prompt_sha256: custom_prompt_sha256,
          service_container_ids: normalized_service_container_ids,
          mcp_servers: normalized_mcp_servers,
          experiments: experiment_definitions(selected_variants)
        }.compact
      )
    end

    def experiment_definitions(selected_variants = nil)
      ConfigurationExperiment::TRACKED_CONFIG_KEYS.each_with_object({}) do |config_key, definitions|
        experiment = ConfigurationExperiment.active_for(config_key, project: agent_run.project, agent_run: agent_run)
        next unless experiment

        assignment = ConfigurationExperiments::Assign.call(
          configuration_experiment: experiment,
          agent_run: agent_run,
          variant: selected_variants&.[](experiment.id)
        )
        parsed_value = parsed_assignment_value(assignment, experiment:)
        next if parsed_value.equal?(INVALID_EXPERIMENT_VALUE)

        definitions[config_key] = {
          configuration_experiment_id: experiment.id,
          configuration_experiment_variant_id: assignment.configuration_experiment_variant_id,
          value: parsed_value
        }
      end
    end

    def parsed_assignment_value(assignment, experiment:)
      assignment.configuration_experiment_variant.parsed_value
    rescue StandardError => e
      assignment.destroy! if assignment.persisted?

      Rails.logger.warn(
        message: "configuration_bundles.invalid_experiment_value_skipped",
        agent_run_id: agent_run.id,
        configuration_experiment_id: experiment.id,
        configuration_experiment_variant_id: assignment.configuration_experiment_variant_id,
        error_class: e.class.name,
        error: e.message
      )

      INVALID_EXPERIMENT_VALUE
    end

    def optimizer_selection
      ConfigurationBundles::Optimizer.call(agent_run: agent_run)
    rescue StandardError => e
      Rails.logger.warn(
        message: "configuration_bundles.optimizer_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    def default_selection_context
      agent_run.issue_id.present? ? "task" : "project"
    end
  end
end
