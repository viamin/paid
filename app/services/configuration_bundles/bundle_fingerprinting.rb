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

    def normalized_service_container_ids
      ids = Array(agent_run.service_container_ids).map { |id| Integer(id, exception: false) || id }.compact.sort
      ids if ids.any?
    end

    def normalized_mcp_servers
      servers = Array(agent_run.mcp_server_snapshot).filter_map { |snapshot| snapshot["name"].presence }.sort
      servers if servers.any?
    end
  end
end
