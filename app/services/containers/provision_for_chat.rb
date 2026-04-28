# frozen_string_literal: true

require "docker-api"

module Containers
  # Provisions a Docker container for interactive chat sessions.
  #
  # Chat containers differ from agent run containers:
  # - Lower resource defaults (2GB RAM, 1 CPU vs 4GB/2 CPU)
  # - Persistent named volume for agent CLI state (~/.claude, ~/.codex, etc.)
  # - Workspace volume seeded from the project's git repo (when project is present)
  # - Idle timeout management (30 min default)
  # - Network access to Paid MCP server
  #
  # @example
  #   result = Containers::ProvisionForChat.call(chat_session: session)
  #   if result.success?
  #     session.reload
  #     # container_id and workspace_volume are now set
  #   end
  class ProvisionForChat
    CHAT_DEFAULTS = {
      memory_bytes: 2 * 1024 * 1024 * 1024,   # 2GB (vs 4GB for agent runs)
      cpu_quota: 100_000,                       # 1 CPU (vs 2 for agent runs)
      pids_limit: 500,
      idle_timeout: 30.minutes,
      image: "paid-agent:latest",
      user: "agent",
      workspace_mount: "/workspace"
    }.freeze

    STATE_VOLUME_DIRS = %w[
      /home/agent/.claude
      /home/agent/.codex
      /home/agent/.gemini
      /home/agent/.cursor-agent
      /home/agent/.cache
    ].freeze

    CLONE_TIMEOUT = 300 # 5 minutes

    Result = Containers::Provision::Result

    class Error < StandardError; end
    class ProvisionError < Error; end

    attr_reader :chat_session, :container, :options

    def self.call(chat_session:, **options)
      new(chat_session: chat_session, **options).call
    end

    def initialize(chat_session:, **options)
      @chat_session = chat_session
      @options = CHAT_DEFAULTS.merge(options)
      @container = nil
    end

    def call
      log("provision.start")

      workspace_volume = create_workspace_volume
      state_volume = create_state_volume

      @container = create_container(
        workspace_volume: workspace_volume,
        state_volume: state_volume
      )
      @container.start
      fix_ownership!
      seed_workspace!

      chat_session.update!(
        container_id: @container.id,
        workspace_volume: workspace_volume,
        idle_timeout_at: options[:idle_timeout].from_now
      )

      log("provision.success", container_id: @container.id)
      Result.success(
        container_id: @container.id,
        workspace_volume: workspace_volume,
        state_volume: state_volume
      )
    rescue Docker::Error::DockerError => e
      log("provision.failed", error: e.message)
      cleanup_on_failure(workspace_volume, state_volume)
      raise ProvisionError, "Docker error: #{e.message}"
    rescue StandardError => e
      log("provision.failed", error: e.message)
      cleanup_on_failure(workspace_volume, state_volume)
      raise
    end

    private

    def project
      chat_session.project
    end

    def create_workspace_volume
      name = "paid-chat-workspace-#{chat_session.id}"
      begin
        Docker::Volume.get(name)
      rescue Docker::Error::NotFoundError
        Docker::Volume.create(name, volume_labels("workspace"))
      end
      name
    end

    def create_state_volume
      name = "paid-chat-state-#{chat_session.id}"
      begin
        Docker::Volume.get(name)
      rescue Docker::Error::NotFoundError
        Docker::Volume.create(name, volume_labels("state"))
      end
      name
    end

    def volume_labels(resource)
      labels = {
        "paid.managed" => "true",
        "paid.resource" => "chat_#{resource}_volume",
        "paid.chat_session_id" => chat_session.id.to_s
      }
      labels["paid.project_id"] = project.id.to_s if project
      { "Labels" => labels }
    end

    def create_container(workspace_volume:, state_volume:)
      Docker::Container.create(
        "Image" => options[:image],
        "name" => container_name,
        "User" => options[:user],
        "ReadonlyRootfs" => true,
        "CapDrop" => [ "ALL" ],
        "CapAdd" => [ "NET_RAW" ],
        "SecurityOpt" => [ "no-new-privileges:true" ],
        "HostConfig" => host_config(workspace_volume, state_volume),
        "Env" => environment_variables,
        "WorkingDir" => options[:workspace_mount],
        "Labels" => container_labels,
        "Tty" => false,
        "OpenStdin" => false,
        "Cmd" => [ "tail", "-f", "/dev/null" ]
      )
    end

    def host_config(workspace_volume, state_volume)
      binds = [
        "#{workspace_volume}:#{options[:workspace_mount]}:rw"
      ] + state_volume_binds(state_volume)

      tmpfs = {
        "/tmp" => "exec,size=#{512 * 1024 * 1024},mode=1777"
      }

      {
        "Memory" => options[:memory_bytes],
        "MemorySwap" => options[:memory_bytes],
        "CpuPeriod" => 100_000,
        "CpuQuota" => options[:cpu_quota],
        "PidsLimit" => options[:pids_limit],
        "Tmpfs" => tmpfs,
        "Binds" => binds,
        "NetworkMode" => "paid_internal"
      }
    end

    def environment_variables
      env = [
        "HOME=/home/agent"
      ]

      if project
        env << "PROJECT_ID=#{project.id}"
      end

      proxy_base = proxy_base_url
      env << "PAID_MCP_URL=#{proxy_base}/mcp"
      env << "PAID_PROXY_URL=#{proxy_base}"
      env << "CHAT_SESSION_ID=#{chat_session.id}"
      env << "PROXY_TOKEN=#{chat_session.proxy_token}"

      env
    end

    def container_name
      "paid-chat-#{chat_session.id}-#{SecureRandom.hex(4)}"
    end

    def container_labels
      labels = {
        "paid.managed" => "true",
        "paid.resource" => "chat_container",
        "paid.chat_session_id" => chat_session.id.to_s
      }
      labels["paid.project_id"] = project.id.to_s if project
      labels
    end

    def state_volume_binds(state_volume)
      STATE_VOLUME_DIRS.map do |dir|
        subdir = File.basename(dir)
        "#{state_volume}:#{dir}:rw,subpath=#{subdir}"
      end
    end

    def fix_ownership!
      dirs = [ options[:workspace_mount] ] + STATE_VOLUME_DIRS
      cmd_args = [ "chown", "-R", "#{options[:user]}:#{options[:user]}" ] + dirs
      @container.exec(cmd_args, user: "root")
    end

    # Seeds the workspace volume by cloning the project's git repository.
    # The GitHub token is passed as an ephemeral environment variable for the
    # clone command only, not stored in the container environment.
    # Skipped when no project is associated or the project has no active token.
    def seed_workspace!
      return unless project

      github_token = project.github_token
      return unless github_token&.active?

      clone_cmd = "git clone --depth 1 https://x-access-token:$CLONE_TOKEN@github.com/#{project.full_name}.git . 2>&1 || true"

      @container.exec(
        [ "sh", "-c", clone_cmd ],
        user: options[:user],
        wait: CLONE_TIMEOUT,
        Env: [ "CLONE_TOKEN=#{github_token.token}" ]
      )

      log("provision.workspace_seeded", project_id: project.id)
    rescue Docker::Error::DockerError => e
      log("provision.workspace_seed_failed", error: e.message, project_id: project.id)
    end

    def proxy_base_url
      proxy_port = Rails.application.config.x.paid_proxy_port
      "http://web:#{proxy_port}"
    end

    def cleanup_on_failure(workspace_volume, state_volume)
      if @container
        begin
          @container.stop(timeout: 0)
          @container.delete(force: true, v: true)
        rescue Docker::Error::DockerError
          # Container may already be gone
        end
        @container = nil
      end

      remove_volume(workspace_volume)
      remove_volume(state_volume)
    end

    def remove_volume(name)
      return unless name

      Docker::Volume.get(name).remove
    rescue Docker::Error::DockerError
      # Volume may already be removed or in use
    end

    def log(action, **metadata)
      Rails.logger.info(
        message: "container_manager.chat.#{action}",
        chat_session_id: chat_session.id,
        project_id: project&.id,
        **metadata
      )
    end
  end
end
