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
  # The heartbeat file lives on a dedicated bind-mounted directory
  # (/paid-heartbeat inside the container) so it is visible to both the
  # container-side hooks and the host-side watchdog.
  #
  # @example
  #   setup = Containers::HeartbeatSetup.new(
  #     provider: "claude",
  #     worktree_path: "/workspace",
  #     host_heartbeat_path: "/tmp/paid-heartbeat-abc123/.paid-heartbeat"
  #   )
  #   setup.heartbeat_path  # => "/tmp/paid-heartbeat-abc123/.paid-heartbeat"
  #   setup.preparation     # => AgentHarness::ExecutionPreparation (with file writes)
  #   setup.env             # => { "AGENT_HEARTBEAT_PATH" => "/paid-heartbeat/.paid-heartbeat" }
  class HeartbeatSetup
    HEARTBEAT_FILENAME = ".paid-heartbeat"

    CONTAINER_HEARTBEAT_PATH = "/paid-heartbeat/#{HEARTBEAT_FILENAME}"

    SUPPORTED_PROVIDERS = %w[claude codex].freeze

    attr_reader :provider, :worktree_path, :host_heartbeat_path

    def initialize(provider:, worktree_path:, host_heartbeat_path: nil)
      @provider = provider.to_s
      @worktree_path = worktree_path
      @host_heartbeat_path = host_heartbeat_path
    end

    def heartbeat_path
      host_heartbeat_path
    end

    def available?
      host_heartbeat_path.present? && SUPPORTED_PROVIDERS.include?(canonical_provider)
    end

    def env
      return {} unless available?

      { "AGENT_HEARTBEAT_PATH" => CONTAINER_HEARTBEAT_PATH }
    end

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
