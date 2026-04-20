# frozen_string_literal: true

require "json"

module Containers
  # Generates provider-specific heartbeat configuration for container execution.
  #
  # Produces preparation file writes and environment variables that configure
  # the agent CLI to touch a heartbeat file on activity. The container watchdog
  # then uses the file's mtime to distinguish "agent is thinking" from "agent
  # is stuck", suppressing idle/startup timeouts while the agent is active.
  #
  # @example
  #   setup = Containers::HeartbeatSetup.new(provider: "claude", worktree_path: "/var/paid/ws/123")
  #   setup.heartbeat_path       # => "/var/paid/ws/123/.paid-heartbeat"
  #   setup.preparation          # => AgentHarness::ExecutionPreparation (with file writes)
  #   setup.env                  # => { "AGENT_HEARTBEAT_PATH" => "/workspace/.paid-heartbeat" }
  class HeartbeatSetup
    HEARTBEAT_FILENAME = ".paid-heartbeat"

    # Container-side path where the heartbeat file is touched.
    CONTAINER_HEARTBEAT_PATH = "/workspace/#{HEARTBEAT_FILENAME}"

    # Providers that support heartbeat hooks.
    # Codex heartbeat is handled by Provision#seed_codex_notify_hook! which
    # appends a notify command to the full config.toml written during
    # container provisioning. HeartbeatSetup still advertises availability so
    # the container watchdog checks the host-visible heartbeat file.
    SUPPORTED_PROVIDERS = %w[claude codex].freeze

    attr_reader :provider, :worktree_path

    def initialize(provider:, worktree_path:)
      @provider = provider.to_s
      @worktree_path = worktree_path
    end

    # Host-visible path the watchdog checks via File.mtime.
    # Returns nil when the workspace is not bind-mounted (Docker volume).
    def heartbeat_path
      return nil unless worktree_path.present?

      File.join(worktree_path, HEARTBEAT_FILENAME)
    end

    # Whether this provider/workspace combination supports heartbeat.
    def available?
      heartbeat_path.present? && SUPPORTED_PROVIDERS.include?(canonical_provider)
    end

    # Environment variables to inject into the agent command.
    def env
      return {} unless available?

      { "AGENT_HEARTBEAT_PATH" => CONTAINER_HEARTBEAT_PATH }
    end

    # Execution preparation with provider-specific config file writes.
    # Returns nil when heartbeat is not available.
    def preparation
      return nil unless available?

      file_writes = preparation_file_writes
      return nil if file_writes.empty?

      AgentHarness::ExecutionPreparation.new(file_writes: file_writes)
    end

    private

    def canonical_provider
      case provider
      when "claude", "claude_code" then "claude"
      else provider
      end
    end

    def preparation_file_writes
      case canonical_provider
      when "claude" then claude_file_writes
      when "codex" then []
      else []
      end
    end

    def claude_file_writes
      settings = existing_claude_settings
      hooks = settings["hooks"] ||= {}
      post_tool = hooks["PostToolUse"] ||= []

      post_tool << {
        "matcher" => "",
        "hooks" => [
          {
            "type" => "command",
            "command" => "touch #{CONTAINER_HEARTBEAT_PATH}"
          }
        ]
      }

      [
        AgentHarness::ExecutionPreparation::FileWrite.new(
          path: "/workspace/.claude/settings.json",
          content: JSON.pretty_generate(settings)
        )
      ]
    end

    def existing_claude_settings
      return {} unless worktree_path.present?

      host_settings_path = File.join(worktree_path, ".claude", "settings.json")
      return {} unless File.exist?(host_settings_path)

      JSON.parse(File.read(host_settings_path))
    rescue JSON::ParserError
      {}
    end
  end
end
