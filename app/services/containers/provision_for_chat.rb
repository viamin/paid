# frozen_string_literal: true

require "docker-api"
require "shellwords"

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

      workspace_volume, workspace_volume_created = create_workspace_volume
      state_volume, state_volume_created = create_state_volume

      @container = create_container(
        workspace_volume: workspace_volume,
        state_volume: state_volume
      )
      Containers.backend.start_container(@container)
      fix_ownership!
      seed_workspace!(workspace_volume_created:)

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
      cleanup_on_failure(
        workspace_volume,
        state_volume,
        workspace_volume_created:,
        state_volume_created:
      )
      raise ProvisionError, "Docker error: #{e.message}"
    rescue StandardError => e
      log("provision.failed", error: e.message)
      cleanup_on_failure(
        workspace_volume,
        state_volume,
        workspace_volume_created:,
        state_volume_created:
      )
      raise
    end

    private

    def project
      chat_session.project
    end

    def create_workspace_volume
      name = "paid-chat-workspace-#{chat_session.id}"
      begin
        Containers.backend.get_volume(name)
        [ name, false ]
      rescue Docker::Error::NotFoundError
        Containers.backend.create_volume(name, volume_labels("workspace"))
        [ name, true ]
      end
    end

    def create_state_volume
      name = "paid-chat-state-#{chat_session.id}"
      begin
        Containers.backend.get_volume(name)
        [ name, false ]
      rescue Docker::Error::NotFoundError
        Containers.backend.create_volume(name, volume_labels("state"))
        [ name, true ]
      end
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
      Containers.backend.create_container(
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
        "#{workspace_volume}:#{options[:workspace_mount]}:rw",
        "#{state_volume}:/home/agent:rw"
      ]

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
      proxy_token = chat_session.ensure_proxy_token!
      proxy_credential = "paid-chat-session:#{chat_session.id}:#{proxy_token}"

      env << "PAID_MCP_URL=#{proxy_base}/mcp"
      env << "PAID_PROXY_URL=#{proxy_base}"
      env << "CHAT_SESSION_ID=#{chat_session.id}"
      env << "PROXY_TOKEN=#{proxy_token}"
      env << "X_API_KEY=#{proxy_credential}"

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

    def fix_ownership!
      initialize_state_directories!

      dirs = [ options[:workspace_mount] ] + STATE_VOLUME_DIRS
      cmd_args = [ "chown", "-R", "#{options[:user]}:#{options[:user]}" ] + dirs
      Containers.backend.exec_in_container(@container, cmd_args, user: "root")
    end

    def initialize_state_directories!
      Containers.backend.exec_in_container(@container, [ "mkdir", "-p", *STATE_VOLUME_DIRS ], user: "root")
    end

    # Seeds the workspace volume by cloning the project's git repository.
    # The GitHub token is passed as an ephemeral environment variable for the
    # clone command only, not stored in the container environment.
    # Skipped when no project is associated.
    # Raises ProvisionError if the project has no active token or the clone fails,
    # since mounting the project repo is a core acceptance criterion for workspace mode.
    #
    # On a successful clone, persists a manifest entry on the chat session so
    # workspace mutation tools (write_repo_file, apply_patch, git_*) can
    # authorize against the cloned repo via session.clone_manifest_entries.
    def seed_workspace!(workspace_volume_created:)
      return unless project

      unless workspace_volume_created || workspace_empty?
        log("provision.workspace_reused", project_id: project.id)
        return
      end

      github_token = project.github_token
      unless github_token&.active?
        raise ProvisionError, "Project #{project.full_name} has no active GitHub token; cannot seed workspace"
      end

      clone_cmd = "git clone --depth 1 https://x-access-token:$CLONE_TOKEN@github.com/#{Shellwords.escape(project.full_name)}.git . 2>&1"

      result = Containers.backend.exec_in_container(
        @container,
        [ "sh", "-c", clone_cmd ],
        user: options[:user],
        wait: CLONE_TIMEOUT,
        Env: [ "CLONE_TOKEN=#{github_token.token}" ]
      )

      exit_code = if result.is_a?(Array)
        result[2]
      else
        log("provision.unexpected_exec_result", result_class: result.class.name)
        -1
      end
      if exit_code != 0
        output = result.is_a?(Array) ? result[0..1].flatten.join("\n").truncate(500) : ""
        raise ProvisionError, "Workspace clone failed (exit #{exit_code}): #{output}"
      end

      record_clone_manifest_entry!
      log("provision.workspace_seeded", project_id: project.id)
    end

    def record_clone_manifest_entry!
      entry = { project_id: project.id, path: options[:workspace_mount] }
      existing = Array(chat_session.clone_manifest)
      chat_session.update!(clone_manifest: existing + [ entry ])
    end

    def workspace_empty?
      result = Containers.backend.exec_in_container(
        @container,
        [ "sh", "-c", "if [ -z \"$(ls -A . 2>/dev/null)\" ]; then exit 0; fi; exit 1" ],
        user: options[:user]
      )

      result.is_a?(Array) && result[2] == 0
    end

    def proxy_base_url
      proxy_port = Rails.application.config.x.paid_proxy_port
      "http://web:#{proxy_port}"
    end

    def cleanup_on_failure(workspace_volume, state_volume, workspace_volume_created:, state_volume_created:)
      if @container
        begin
          Containers.backend.stop_container(@container, timeout: 0)
          Containers.backend.delete_container(@container, force: true, v: true)
        rescue Docker::Error::DockerError
          # Container may already be gone
        end
        @container = nil
      end

      remove_volume(workspace_volume) if workspace_volume_created
      remove_volume(state_volume) if state_volume_created
    end

    def remove_volume(name)
      return unless name

      Containers.backend.delete_volume(Containers.backend.get_volume(name))
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
