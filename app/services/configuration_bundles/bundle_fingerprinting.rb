# frozen_string_literal: true

require "digest"

module ConfigurationBundles
  module BundleFingerprinting
    include Canonicalization

    BUNDLE_IDENTITY_SCHEMA_VERSION = 2
    BUNDLE_FINGERPRINT_ALGORITHM = "sha256"

    private

    def bundle_fingerprint(definition)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(definition)))
    end

    def bundle_identity_metadata(definition)
      {
        "fingerprint" => bundle_fingerprint(definition),
        "fingerprint_algorithm" => BUNDLE_FINGERPRINT_ALGORITHM,
        "schema_version" => BUNDLE_IDENTITY_SCHEMA_VERSION
      }
    end

    def custom_prompt_sha256
      return if agent_run.custom_prompt.blank?

      Digest::SHA256.hexdigest(agent_run.custom_prompt)
    end

    def model_selection_definition
      selection = agent_run.model_selection
      return unless selection

      canonicalize(
        {
          tier: selection.tier,
          selector_type: selection.selector_type,
          escalated_from_tier: selection.escalated_from_tier,
          escalated_reason: selection.escalated_reason
        }.compact
      )
    end

    def ordered_runner_set
      runner_key =
        if agent_run.respond_to?(:runner) && agent_run.runner&.runner_key.present?
          agent_run.runner.runner_key
        elsif agent_run.respond_to?(:effective_runner) && agent_run.effective_runner.present?
          agent_run.effective_runner
        else
          RunnerSupport.runner_key_for_agent_type(agent_run.agent_type)
        end

      return if runner_key.blank?

      [ runner_key ]
    end

    def normalized_service_container_ids
      ids = agent_run.project.service_container_ids
      ids = Array(agent_run.service_container_ids) if ids.empty?
      ids = ids.map { |id| Integer(id, exception: false) || id }.compact.sort
      ids if ids.any?
    end

    def normalized_mcp_servers
      servers = super(agent_run.mcp_server_snapshot)
      servers if servers.any?
    end
  end
end
