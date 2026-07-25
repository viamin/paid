# frozen_string_literal: true

module Containers
  # Sets up rtk (shell-output compression) and CodeGraph (code knowledge graph)
  # inside agent containers to reduce token consumption during agent runs.
  #
  # Both tools are non-fatal optimizations — a failure to initialize either one
  # is logged as a warning and the agent run proceeds without the optimization.
  module TokenOptimization
    # Maps Paid runner keys to the extra flags rtk needs for that runner's
    # hook mechanism. Runners not listed here are skipped (rtk stays inert).
    # Claude/Copilot share the default init (no extra flags).
    RTK_RUNNER_FLAGS = {
      "claude" => %w[],
      "claude_code" => %w[],
      "copilot" => %w[],
      "codex" => %w[--codex],
      "gemini" => %w[--gemini],
      "opencode" => %w[--opencode],
      "cursor" => %w[--agent cursor]
    }.freeze

    CODEGRAPH_INIT_TIMEOUT = 120
    CODEGRAPH_INSTALL_TIMEOUT = 30
    RTK_INIT_TIMEOUT = 30

    # Initializes rtk hooks for the specific runner inside an already-started
    # container. Uses --hook-only to avoid injecting RTK.md into the agent's
    # context (zero added tokens), and --auto-patch for non-interactive setup.
    def self.rtk_init_for_runner(container_service:, runner_key:)
      flags = RTK_RUNNER_FLAGS[runner_key.to_s]
      return unless flags # runner not supported by rtk

      command = [ "rtk", "init", "-g", "--auto-patch", "--hook-only", *flags ]
      container_service.execute(command, timeout: RTK_INIT_TIMEOUT)
      Rails.logger.info(message: "container_manager.rtk_initialized", runner: runner_key.to_s)
    rescue => e
      Rails.logger.warn(
        message: "container_manager.rtk_init_failed",
        runner: runner_key.to_s,
        error: e.message
      )
    end

    # Builds the CodeGraph knowledge graph inside the workspace and configures
    # the MCP server for all detected agents. Should be called after the repo
    # is cloned so the full tree is available for indexing.
    def self.codegraph_setup(container_service:)
      codegraph_init(container_service: container_service)
      codegraph_install(container_service: container_service)
    end

    # Builds the graph in .codegraph/codegraph.db inside /workspace.
    def self.codegraph_init(container_service:)
      container_service.execute([ "codegraph", "init" ], timeout: CODEGRAPH_INIT_TIMEOUT)
      Rails.logger.info(message: "container_manager.codegraph_initialized")
    rescue => e
      Rails.logger.warn(
        message: "container_manager.codegraph_init_failed",
        error: e.message
      )
    end

    # Configures codegraph as a global MCP server for all detected agents.
    # Uses --location=global so project files (CLAUDE.md/AGENTS.md) are not
    # modified — the MCP config goes into each agent's global config on tmpfs.
    def self.codegraph_install(container_service:)
      container_service.execute(
        [ "codegraph", "install", "--yes", "--location=global", "--no-permissions" ],
        timeout: CODEGRAPH_INSTALL_TIMEOUT
      )
      Rails.logger.info(message: "container_manager.codegraph_mcp_configured")
    rescue => e
      Rails.logger.warn(
        message: "container_manager.codegraph_install_failed",
        error: e.message
      )
    end
  end
end
