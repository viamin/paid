# frozen_string_literal: true

require "digest"

module ConfigurationBundles
  class AssignToRun
    include BundleFingerprinting

    INVALID_EXPERIMENT_VALUE = Object.new
    FingerprintMismatchError = Class.new(StandardError)

    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      selection = optimizer_selection
      definition, fingerprint = selected_bundle_payload(selection)
      log_selection_fingerprint_mismatch(selection:, fingerprint:) if selection

      bundle = find_or_create_bundle(fingerprint:, definition:)
      agent_run.update!(
        configuration_bundle: bundle,
        configuration_bundle_selection_mode: selection&.selection_mode,
        configuration_bundle_selection_context: selection&.selection_context
      )
      bundle
    end

    private

    def find_or_create_bundle(fingerprint:, definition:)
      existing_bundle = bundle_scope.find_by(fingerprint: fingerprint)
      return existing_bundle if existing_bundle&.definition == definition
      raise FingerprintMismatchError, "Configuration bundle fingerprint collision for account #{account.id}" if existing_bundle

      account.with_lock do
        bundle_scope.find_by(fingerprint: fingerprint) || create_runtime_bundle(fingerprint:, definition:)
      end
    rescue ActiveRecord::RecordNotUnique
      bundle_scope.find_by!(fingerprint: fingerprint)
    end

    def create_runtime_bundle(fingerprint:, definition:)
      ConfigurationBundle.create!(
        account: account,
        prompt_version: agent_run.prompt_version,
        llm_model: agent_run.model_selection&.llm_model,
        name: "Runtime Bundle #{fingerprint.first(12)}",
        version: next_runtime_bundle_version,
        status: "active",
        strategy: "runtime_snapshot",
        strategy_params: {},
        context: { "identity" => bundle_identity_metadata(definition) },
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
          model_selection: model_selection_definition,
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

    def selected_bundle_payload(selection)
      definition = selection&.definition
      fingerprint = selection&.fingerprint
      computed_fingerprint = bundle_fingerprint(definition) if definition.is_a?(Hash)

      if optimizer_payload_usable?(selection, definition, fingerprint, computed_fingerprint) &&
          persist_optimizer_assignments(selection)
        return [ definition, computed_fingerprint ]
      end

      fallback_definition = bundle_definition(selection&.variant_by_experiment_id)
      [ fallback_definition, bundle_fingerprint(fallback_definition) ]
    end

    def persist_optimizer_assignments(selection)
      optimizer_assignment_inputs(selection).each do |experiment, variant|
        ConfigurationExperiments::Assign.call(
          configuration_experiment: experiment,
          agent_run: agent_run,
          variant: variant
        )
      end

      true
    rescue StandardError => e
      Rails.logger.warn(
        message: "configuration_bundles.optimizer_assignment_persistence_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    def optimizer_assignment_inputs(selection)
      variant_by_experiment_id = selection&.variant_by_experiment_id
      return variant_by_experiment_id.map { |experiment_id, variant| [ optimizer_experiment_for(variant, experiment_id), variant ] } if variant_by_experiment_id.present?

      optimizer_assignment_inputs_from_definition(selection&.definition)
    end

    def optimizer_assignment_inputs_from_definition(definition)
      definition.fetch("experiments", {}).values.filter_map do |experiment_definition|
        experiment_id = experiment_definition["configuration_experiment_id"]
        variant_id = experiment_definition["configuration_experiment_variant_id"]
        next if experiment_id.blank? || variant_id.blank?

        experiment = ConfigurationExperiment.find(experiment_id)
        variant = ConfigurationExperimentVariant.find(variant_id)
        raise ArgumentError, "configuration experiment variant must belong to the same experiment" if variant.configuration_experiment_id != experiment.id

        [ experiment, variant ]
      end
    end

    def optimizer_experiment_for(variant, experiment_id)
      experiment = variant.respond_to?(:configuration_experiment) ? variant.configuration_experiment : nil
      return experiment if experiment&.id == experiment_id

      ConfigurationExperiment.find(experiment_id)
    end

    def optimizer_payload_usable?(selection, definition, fingerprint, computed_fingerprint)
      return false unless definition.is_a?(Hash)
      return false unless optimizer_definition_matches_run?(definition)
      return false unless optimizer_experiments_match_variants?(definition, selection&.variant_by_experiment_id)
      return true if fingerprint.blank?

      return true if fingerprint == computed_fingerprint

      Rails.logger.warn(
        message: "configuration_bundles.optimizer_payload_fingerprint_mismatch",
        agent_run_id: agent_run.id,
        optimizer_fingerprint: fingerprint,
        computed_fingerprint: computed_fingerprint
      )
      false
    end

    def optimizer_experiments_match_variants?(definition, variant_by_experiment_id)
      return true if variant_by_experiment_id.blank?

      expected_experiments = variant_by_experiment_id.each_with_object({}) do |(experiment_id, variant), definitions|
        experiment = optimizer_experiment_for(variant, experiment_id)
        parsed_value = parsed_optimizer_variant_value(variant, experiment:)
        return false if parsed_value.equal?(INVALID_EXPERIMENT_VALUE)

        definitions[experiment.config_key] = {
          "configuration_experiment_id" => experiment.id,
          "configuration_experiment_variant_id" => variant.id,
          "value" => parsed_value
        }
      end

      return true if definition.fetch("experiments", {}) == expected_experiments

      Rails.logger.warn(
        message: "configuration_bundles.optimizer_payload_experiments_mismatch",
        agent_run_id: agent_run.id
      )
      false
    end

    def optimizer_definition_matches_run?(definition)
      return true if definition.except("experiments") == expected_optimizer_definition_attributes

      Rails.logger.warn(
        message: "configuration_bundles.optimizer_payload_definition_mismatch",
        agent_run_id: agent_run.id
      )
      false
    end

    def parsed_optimizer_variant_value(variant, experiment:)
      variant.parsed_value
    rescue StandardError => e
      Rails.logger.warn(
        message: "configuration_bundles.invalid_optimizer_variant_skipped",
        agent_run_id: agent_run.id,
        configuration_experiment_id: experiment.id,
        configuration_experiment_variant_id: variant.id,
        error_class: e.class.name,
        error: e.message
      )

      INVALID_EXPERIMENT_VALUE
    end

    def expected_optimizer_definition_attributes
      canonicalize(
        {
          schema_version: 1,
          goal: agent_run.goal,
          agent_type: agent_run.agent_type,
          provider_id: agent_run.provider_id,
          prompt_version_id: agent_run.prompt_version_id,
          custom_prompt_sha256: custom_prompt_sha256,
          model_selection: model_selection_definition,
          service_container_ids: normalized_service_container_ids,
          mcp_servers: normalized_mcp_servers
        }.compact
      )
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

    def log_selection_fingerprint_mismatch(selection:, fingerprint:)
      return if selection.fingerprint.blank? || selection.fingerprint == fingerprint

      Rails.logger.warn(
        message: "configuration_bundles.selection_fingerprint_mismatch",
        agent_run_id: agent_run.id,
        optimizer_fingerprint: selection.fingerprint,
        resolved_fingerprint: fingerprint
      )
    end
  end
end
