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
    SUPPORTED_PROVIDERS = %w[claude claude_code codex].freeze

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
      when "codex" then "codex"
      else provider
      end
    end

    def preparation_file_writes
      case canonical_provider
      when "claude" then claude_file_writes
      when "codex" then codex_file_writes
      else []
      end
    end

    def claude_file_writes
      settings = {
        "hooks" => {
          "PostToolUse" => [
            {
              "matcher" => "",
              "hooks" => [
                {
                  "type" => "command",
                  "command" => "touch #{CONTAINER_HEARTBEAT_PATH}"
                }
              ]
            }
          ]
        }
      }

      [
        AgentHarness::ExecutionPreparation::FileWrite.new(
          path: "/workspace/.claude/settings.json",
          content: JSON.pretty_generate(settings)
        )
      ]
    end

    def codex_file_writes
      content = <<~TOML
        notify = ["touch", "#{CONTAINER_HEARTBEAT_PATH}"]
      TOML

      [
        AgentHarness::ExecutionPreparation::FileWrite.new(
          path: "~/.codex/config.toml",
          content: content
        )
      ]
    end
  end
end
