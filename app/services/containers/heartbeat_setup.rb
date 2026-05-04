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
  # (/paid-heartbeat inside the container) so it is usually visible to both
  # the container-side hooks and the host-side watchdog.
  #
  # When the host path is unavailable (for example, reconnecting to a
  # volume-backed workspace where only the container can see /paid-heartbeat),
  # the setup still enables provider hooks and returns the container path.
  # The watchdog must then inspect that path from inside the container rather
  # than reading it directly from the host filesystem.
  #
  # Heartbeat availability is determined by querying the upstream agent-harness
  # provider for +supports_activity_heartbeat?+ and its +heartbeat_integration+
  # contract. Providers that the harness does not yet cover (Claude, Codex)
  # fall back to locally managed heartbeat configuration.
  #
  # @example
  #   setup = Containers::HeartbeatSetup.new(
  #     provider: "claude",
  #     worktree_path: "/workspace",
  #     host_heartbeat_path: "/tmp/paid-heartbeat-abc123/.paid-heartbeat",
  #     harness_provider: AgentHarness.provider(:claude)
  #   )
  #   setup.heartbeat_path  # => "/tmp/paid-heartbeat-abc123/.paid-heartbeat"
  #   setup.preparation     # => AgentHarness::ExecutionPreparation (with file writes)
  #   setup.env             # => { "AGENT_HEARTBEAT_PATH" => "/paid-heartbeat/.paid-heartbeat" }
  class HeartbeatSetup
    HEARTBEAT_FILENAME = ".paid-heartbeat"

    CONTAINER_HEARTBEAT_PATH = "/paid-heartbeat/#{HEARTBEAT_FILENAME}"

    # Providers with locally managed heartbeat configuration.
    # These are providers where agent-harness does not yet provide
    # heartbeat integration, so Paid handles the setup directly.
    LOCAL_HEARTBEAT_PROVIDERS = %w[claude codex].freeze

    # Providers with per-tool heartbeat hooks (e.g. Claude PostToolUse)
    # that fire frequently enough to suppress idle timeouts reliably
    # during long subprocess execution. Providers using coarser heartbeat
    # signals that only fire between CLI turns need a longer idle timeout
    # to avoid false positives during long-running commands.
    LOCAL_RELIABLE_HEARTBEAT_PROVIDERS = %w[claude].freeze

    # Upstream heartbeat granularities considered reliable (fire often
    # enough within a single tool execution to suppress idle timeout).
    RELIABLE_GRANULARITIES = %i[tool_call].freeze

    COARSE_HEARTBEAT_IDLE_TIMEOUT_MULTIPLIER = 3

    attr_reader :provider, :worktree_path, :host_heartbeat_path

    def initialize(provider:, worktree_path:, host_heartbeat_path: nil, harness_provider: nil)
      @provider = provider.to_s
      @worktree_path = worktree_path
      @host_heartbeat_path = host_heartbeat_path
      @harness_provider = harness_provider
    end

    def heartbeat_path
      host_heartbeat_path.presence || CONTAINER_HEARTBEAT_PATH
    end

    def available?
      local_heartbeat_provider? || upstream_heartbeat_supported?
    end

    # Returns the effective idle timeout for this provider given a base
    # timeout selected by goal type. Returns nil for providers without
    # heartbeat support (idle timeout disabled entirely).
    def idle_timeout_for(base_timeout)
      return nil unless available?
      return base_timeout if reliable_heartbeat? || base_timeout.nil?

      base_timeout * COARSE_HEARTBEAT_IDLE_TIMEOUT_MULTIPLIER
    end

    def reliable_heartbeat?
      if upstream_heartbeat_supported?
        RELIABLE_GRANULARITIES.include?(upstream_integration[:granularity])
      else
        LOCAL_RELIABLE_HEARTBEAT_PROVIDERS.include?(canonical_provider)
      end
    end

    def env
      return {} unless available?

      if upstream_heartbeat_supported?
        upstream_integration[:env] || {}
      else
        { "AGENT_HEARTBEAT_PATH" => CONTAINER_HEARTBEAT_PATH }
      end
    end

    def preparation
      return nil unless available?

      if upstream_heartbeat_supported?
        upstream_integration[:preparation]
      else
        local_preparation
      end
    end

    private

    def canonical_provider
      case provider
      when "claude", "claude_code" then "claude"
      else provider
      end
    end

    def local_heartbeat_provider?
      LOCAL_HEARTBEAT_PROVIDERS.include?(canonical_provider)
    end

    def upstream_heartbeat_supported?
      return false unless @harness_provider
      return false unless @harness_provider.respond_to?(:supports_activity_heartbeat?)
      return false unless @harness_provider.supports_activity_heartbeat?

      integration = upstream_integration
      integration.is_a?(Hash) && integration[:supported] == true
    end

    def upstream_integration
      @upstream_integration ||= begin
        return {} unless @harness_provider.respond_to?(:heartbeat_integration)

        @harness_provider.heartbeat_integration(
          heartbeat_file_path: CONTAINER_HEARTBEAT_PATH
        ) || {}
      end
    end

    def local_preparation
      file_writes = local_preparation_file_writes
      return nil if file_writes.empty?

      AgentHarness::ExecutionPreparation.new(file_writes: file_writes)
    end

    def local_preparation_file_writes
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
