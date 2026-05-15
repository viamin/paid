# frozen_string_literal: true

require "set"

module MarketplaceEntries
  class RuntimeAttachments
    ALLOWED_ENV_KEY_PATTERN = /\AMARKETPLACE_[A-Z0-9_]+\z/.freeze
    RESTRICTED_ENV_KEYS = %w[
      PATH
      LD_PRELOAD
      LD_LIBRARY_PATH
      HOME
      SHELL
      USER
      LOGNAME
    ].to_set.freeze

    def initialize(agent_run)
      @agent_run = agent_run
    end

    def self.mcp_server_snapshots(agent_run)
      new(agent_run).mcp_server_snapshots
    end

    def self.runtime_env(agent_run)
      new(agent_run).runtime_env
    end

    def self.runtime_preparation(agent_run)
      new(agent_run).runtime_preparation
    end

    def mcp_server_snapshots
      attachments.filter_map do |attachment|
        next unless attachment.rendered_payload["attachment_strategy"] == "mcp_server"

        payload = attachment.rendered_payload["payload"]
        next unless payload.is_a?(Hash)

        payload.merge(
          "marketplace_attachment" => true,
          "marketplace_entry_id" => attachment.marketplace_entry_id,
          "marketplace_entry_version_id" => attachment.marketplace_entry_version_id
        )
      end
    end

    def runtime_env
      attachments.each_with_object({}) do |attachment, env|
        next unless attachment.rendered_payload["attachment_strategy"] == "runtime_config"

        payload = attachment.rendered_payload["payload"]
        next unless payload.is_a?(Hash)

        extract_env(payload).each do |key, value|
          env[key] = value
        end
      end
    end

    def runtime_preparation
      file_writes = attachments.flat_map do |attachment|
        next [] unless attachment.rendered_payload["attachment_strategy"] == "runtime_config"

        payload = attachment.rendered_payload["payload"]
        next [] unless payload.is_a?(Hash)

        extract_file_writes(payload)
      end

      return if file_writes.empty?

      AgentHarness::ExecutionPreparation.new(file_writes: file_writes)
    end

    private

    def attachments
      @attachments ||= @agent_run.agent_run_marketplace_entries.ordered.to_a
    end

    def extract_env(payload)
      env_hash = payload["env"] || payload["service_environment"] || payload["environment"]
      return {} unless env_hash.is_a?(Hash)

      env_hash.each_with_object({}) do |(key, value), env|
        next if key.blank? || value.nil?
        normalized_key = key.to_s.upcase
        next unless allowed_env_key?(normalized_key)

        env[normalized_key] = value.to_s
      end
    end

    def allowed_env_key?(key)
      return false if RESTRICTED_ENV_KEYS.include?(key)

      key.match?(ALLOWED_ENV_KEY_PATTERN)
    end

    def extract_file_writes(payload)
      Array(payload["files"]).filter_map do |file|
        next unless file.is_a?(Hash)

        path = file["path"].to_s.strip
        content = file["content"]
        next if path.blank? || content.nil?
        next if path.start_with?("/") || path.include?("..")

        { path:, content: content.to_s }
      end
    end
  end
end
