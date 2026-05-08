# frozen_string_literal: true

require "digest"

module ConfigurationBundles
  module BundleFingerprinting
    include Canonicalization

    private

    def custom_prompt_sha256
      return if agent_run.custom_prompt.blank?

      Digest::SHA256.hexdigest(agent_run.custom_prompt)
    end

    def model_selection_definition
      selection = agent_run.model_selection
      return unless selection

      canonicalize(
        {
          llm_model_id: selection.llm_model.model_id,
          llm_provider: selection.llm_model.provider,
          selector_type: selection.selector_type,
          tier: selection.tier,
          escalated_from_tier: selection.escalated_from_tier,
          escalated_reason: selection.escalated_reason
        }.compact
      )
    end

    def normalized_service_container_ids
      ids = agent_run.project.service_container_ids
      ids = Array(agent_run.service_container_ids) if ids.empty?
      ids = ids.map { |id| Integer(id, exception: false) || id }.compact.sort
      ids if ids.any?
    end

    def normalized_mcp_servers
      servers = Array(agent_run.mcp_server_snapshot).filter_map do |snapshot|
        next unless snapshot.is_a?(Hash)

        canonicalize(snapshot)
      end
      servers = servers.sort_by { |snapshot| JSON.generate(snapshot) }
      servers if servers.any?
    end
  end
end
