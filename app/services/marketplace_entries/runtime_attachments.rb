# frozen_string_literal: true

require "set"

module MarketplaceEntries
  class RuntimeAttachments
    RUNTIME_PREPARATION_ROOT = Rails.root.to_s.freeze
    RUNTIME_HOME_ROOT = "/home/agent".freeze
    ALLOWED_ENV_KEY_PATTERN = /\A[A-Z][A-Z0-9_]*\z/.freeze
    RESTRICTED_ENV_KEYS = %w[
      PATH
      LD_PRELOAD
      LD_LIBRARY_PATH
      HOME
      SHELL
      USER
      LOGNAME
      DISPLAY
      TERM
      LANG
      LC_ALL
      TMPDIR
      EDITOR
      VISUAL
    ].to_set.freeze

    def initialize(agent_run, provider_key: nil)
      @agent_run = agent_run
      @provider_key = provider_key
    end

    def self.mcp_server_snapshots(agent_run, provider_key: nil)
      new(agent_run, provider_key: provider_key).mcp_server_snapshots
    end

    def self.runtime_env(agent_run, provider_key: nil)
      new(agent_run, provider_key: provider_key).runtime_env
    end

    def self.runtime_preparation(agent_run, provider_key: nil)
      new(agent_run, provider_key: provider_key).runtime_preparation
    end

    def mcp_server_snapshots
      attachments.filter_map do |attachment|
        rendered_payload = rendered_payload_for(attachment)
        next unless rendered_payload["attachment_strategy"] == "mcp_server"

        payload = rendered_payload["payload"]
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
        rendered_payload = rendered_payload_for(attachment)
        next unless rendered_payload["attachment_strategy"] == "runtime_config"

        payload = rendered_payload["payload"]
        next unless payload.is_a?(Hash)

        extract_env(payload).each do |key, value|
          env[key] = value
        end
      end
    end

    def runtime_preparation
      file_writes = attachments.flat_map do |attachment|
        rendered_payload = rendered_payload_for(attachment)
        next [] unless rendered_payload["attachment_strategy"] == "runtime_config"

        payload = rendered_payload["payload"]
        next [] unless payload.is_a?(Hash)

        extract_file_writes(payload)
      end

      return if file_writes.empty?

      AgentHarness::ExecutionPreparation.new(file_writes: file_writes)
    end

    private

    def attachments
      @attachments ||= begin
        relation = @agent_run.agent_run_marketplace_entries
        relation = relation.includes(:marketplace_entry, :marketplace_entry_version) if relation.respond_to?(:includes)
        relation.ordered.to_a
      end
    end

    def rendered_payload_for(attachment)
      Renderer.for_attachment(attachment, provider_key: @provider_key)
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

        normalized_path = path.sub(/\A~(?=\/|$)/, RUNTIME_HOME_ROOT)
        expanded_path = File.expand_path(normalized_path, RUNTIME_PREPARATION_ROOT)
        resolved_path = resolve_runtime_path(expanded_path)
        next unless allowed_runtime_path?(resolved_path)

        { path: normalized_path, content: content.to_s }
      end
    end

    def resolve_runtime_path(path)
      File.realpath(path)
    rescue Errno::ENOENT
      resolved_dir = resolve_existing_parent(File.dirname(path))
      File.join(resolved_dir, File.basename(path))
    rescue Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP
      path
    end

    def resolve_existing_parent(path)
      current_path = path

      loop do
        return File.realpath(current_path)
      rescue Errno::ENOENT
        parent_path = File.dirname(current_path)
        raise if parent_path == current_path

        current_path = parent_path
      end
    end

    def allowed_runtime_path?(resolved_path)
      [ RUNTIME_PREPARATION_ROOT, RUNTIME_HOME_ROOT ].any? do |root|
        resolved_path == root || resolved_path.start_with?("#{root}/")
      end
    end
  end
end
