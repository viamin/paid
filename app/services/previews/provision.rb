# frozen_string_literal: true

require "json"
require "shellwords"
require "uri"

module Previews
  class Provision
    APP_LOG_PATH = "tmp/paid-preview-app.log"
    APP_PID_PATH = "tmp/paid-preview-app.pid"
    PHOENIX_PREVIEW_CONFIG_PATH = "config/paid_preview.exs"
    MEMORY_BYTES = Screenshots::ContainerCapture::MEMORY_BYTES
    CPU_QUOTA = Screenshots::ContainerCapture::CPU_QUOTA
    PIDS_LIMIT = Screenshots::ContainerCapture::PIDS_LIMIT
    STARTUP_TIMEOUT_SECONDS = Screenshots::ContainerCapture::STARTUP_TIMEOUT_SECONDS
    PROVISION_TIMEOUT_SECONDS = Screenshots::ContainerCapture::CAPTURE_TIMEOUT_SECONDS

    Result = Struct.new(
      :container_service,
      :config,
      :network_name,
      :service_environment,
      :service_container_ids,
      :seed_data,
      :tunnel_port,
      :tunnel_token,
      keyword_init: true
    )

    attr_reader :agent_run, :project, :repo_path, :logger, :config, :container_service

    def initialize(agent_run:, repo_path:, preview_session: nil, logger: Rails.logger,
      service_provisioner: Containers::ServiceProvisioner.new, seed_runner: Screenshots::SeedRunner.new,
      tunnel_manager: nil)
      @agent_run = agent_run
      @project = agent_run.project
      @repo_path = repo_path
      @preview_session = preview_session
      @logger = logger
      @service_provisioner = service_provisioner
      @seed_runner = seed_runner
      @tunnel_manager = tunnel_manager || Previews::TunnelManager.new(preview_session:, logger:)
      @container_service = nil
      @network_name = nil
      @service_environment = {}
      @service_container_ids = []
      @seed_data = {}
      @tunnel_port = nil
    end

    def call(start_tunnel: true, allow_seed: true)
      prepare_workspace!
      boot!(start_tunnel:, allow_seed:)
    end

    def prepare_workspace!
      return self if @config.present?

      provision_container!
      checkout_branch!
      @config = Screenshots::ConfigParser.from_repo_path(repo_path, project:)
      update_preview_session!(status: "provisioning", container_id: container_service.container&.id)
      self
    end

    def boot!(start_tunnel: true, allow_seed: true)
      prepare_workspace!
      provision_service_dependencies!
      run_setup_commands!
      load_seed_data! if allow_seed
      start_application!
      start_tunnel! if start_tunnel

      update_preview_session!(status: "ready", container_id: container_service.container&.id, tunnel_port: @tunnel_port)

      Result.new(
        container_service:,
        config:,
        network_name: @network_name,
        service_environment: @service_environment.dup,
        service_container_ids: @service_container_ids.dup,
        seed_data: @seed_data,
        tunnel_port: @tunnel_port,
        tunnel_token: @tunnel_manager.token
      )
    end

    def cleanup!
      @tunnel_manager.stop_client!(container_service:) if @tunnel_port.present? && container_service.present?
      @tunnel_manager.release_port!
      cleanup_services!
      container_service&.cleanup(force: true)
    rescue StandardError => e
      logger.warn(message: "previews.provision.cleanup_failed", agent_run_id: agent_run.id, error: e.message)
    end

    def service_environment
      @service_environment
    end

    def network_name
      @network_name
    end

    private

    attr_reader :preview_session, :service_provisioner, :seed_runner

    def provision_container!
      @container_service = Containers::Provision.new(
        project:,
        worktree_path: repo_path,
        memory_bytes: MEMORY_BYTES,
        cpu_quota: CPU_QUOTA,
        pids_limit: PIDS_LIMIT,
        timeout_seconds: PROVISION_TIMEOUT_SECONDS
      )
      @container_service.provision
      @network_name = @container_service.network_name
    end

    def checkout_branch!
      git_ops = Containers::GitOperations.new(
        container_service:,
        agent_run:
      )
      git_ops.clone_and_checkout_branch(
        branch_name: agent_run.branch_name,
        pull_request_number: agent_run.pull_request_number,
        persist: false
      )
      git_ops.install_artifact_excludes
    end

    def provision_service_dependencies!
      service_names = configured_service_dependencies
      return if service_names.empty?

      original_ids = agent_run.service_container_ids.dup
      original_env = agent_run.service_environment&.deep_dup

      service_provisioner.provision(agent_run, network: @network_name, service_names:)

      @service_environment = agent_run.service_environment&.deep_dup || {}
    ensure
      current_ids = agent_run.service_container_ids
      @service_container_ids |= current_ids - (original_ids || current_ids)

      needs_restore = original_ids && (current_ids != original_ids || agent_run.service_environment != original_env)
      if needs_restore
        agent_run.update!(
          service_container_ids: original_ids,
          service_environment: original_env
        )
      end
    end

    def configured_service_dependencies
      project_services = Array(project.effective_screenshot_settings["service_dependencies"])
      (project_services + Array(config.services)).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    def run_setup_commands!
      config.setup_commands.each do |command|
        result = container_service.execute(command, timeout: PROVISION_TIMEOUT_SECONDS, env: preview_env, stream: false)
        next if result.success?

        raise "setup command failed: #{command}\n#{result[:stderr].presence || result[:stdout]}"
      end
    end

    def load_seed_data!
      return unless repo_seed_configured?
      return if config.seed.empty?

      @seed_data = seed_runner.call(
        config:,
        repo_path:,
        driver_name: config.driver,
        force: true,
        executor: method(:execute_seed_in_container)
      )
    end

    def start_application!
      prepare_phoenix_preview_config! if detected_framework == :phoenix
      command = application_start_command
      raise Screenshots::ConfigError, "could not determine how to start the preview application" if command.blank?

      launch_command = <<~SH
        set -e
        mkdir -p tmp
        (#{command}) > #{Shellwords.escape(APP_LOG_PATH)} 2>&1 &
        echo $! > #{Shellwords.escape(APP_PID_PATH)}
      SH
      container_service.execute(launch_command, timeout: 30, env: preview_env, stream: false)

      container_service.execute(
        readiness_probe_command,
        timeout: STARTUP_TIMEOUT_SECONDS,
        startup_timeout: STARTUP_TIMEOUT_SECONDS,
        idle_timeout: STARTUP_TIMEOUT_SECONDS,
        env: preview_env,
        stream: false
      )
    rescue Containers::Provision::ExecutionError => e
      app_log = read_file(APP_LOG_PATH)
      raise "preview application startup failed: #{e.message}\n#{app_log}".strip
    end

    def start_tunnel!
      @tunnel_port = @tunnel_manager.allocate_port!
      @tunnel_manager.start_client!(container_service:, local_port: app_port, remote_port: @tunnel_port)
      @tunnel_manager.wait_until_healthy!(
        port: @tunnel_port,
        path: readiness_path,
        timeout_seconds: STARTUP_TIMEOUT_SECONDS
      )
    end

    def preview_env
      @service_environment.merge("CI" => "1")
    end

    def application_start_command
      framework = detected_framework
      port = app_port

      if File.exist?(File.join(repo_path, "bin/dev"))
        "PORT=#{port} bin/dev"
      elsif framework == :rails && File.exist?(File.join(repo_path, "bin/rails"))
        "bundle exec bin/rails server -b 0.0.0.0 -p #{port}"
      elsif framework == :phoenix && File.exist?(File.join(repo_path, "mix.exs"))
        "PORT=#{port} MIX_ENV=dev mix phx.server"
      elsif framework == :django && File.exist?(File.join(repo_path, "manage.py"))
        "python3 manage.py runserver 0.0.0.0:#{port}"
      elsif framework == :nextjs && package_dependency?("next")
        "yarn next dev --hostname 0.0.0.0 --port #{port}"
      elsif package_dependency?("vite")
        "yarn vite --host 0.0.0.0 --port #{port}"
      elsif File.exist?(File.join(repo_path, "package.json"))
        "yarn dev --host 0.0.0.0 --port #{port}"
      end
    end

    def detected_framework
      @detected_framework ||= begin
        overrides = Screenshots::ConfigParser.ui_detection_overrides(project:, repo_path:)
        overrides[:framework] || Screenshots::DetectFramework.detect_framework_only(repo_path:)
      end
    end

    def readiness_probe_command
      host = readiness_host
      port = app_port
      path = readiness_path

      <<~SH.squish
        PREVIEW_APP_HOST=#{Shellwords.escape(host)}
        PREVIEW_APP_PORT=#{Shellwords.escape(port.to_s)}
        PREVIEW_APP_PATH=#{Shellwords.escape(path)}
        ruby -rnet/http -ruri -e '
          deadline = Time.now + #{STARTUP_TIMEOUT_SECONDS};
          uri = URI("http://\#{ENV.fetch("PREVIEW_APP_HOST")}:\#{ENV.fetch("PREVIEW_APP_PORT")}\#{ENV.fetch("PREVIEW_APP_PATH")}");
          loop do
            begin
              response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) { |http| http.get(uri.request_uri) };
              exit 0 if response.code.to_i < 500;
            rescue StandardError
            end
            raise "timeout" if Time.now >= deadline;
            sleep 2;
          end
        '
      SH
    end

    def app_port
      uri = URI.parse(config&.base_url || Screenshots::Configuration::DEFAULT_BASE_URL)
      uri.port || 3000
    end

    def readiness_host
      uri = URI.parse(config.base_url)
      uri.host.presence || "127.0.0.1"
    end

    def readiness_path
      uri = URI.parse(config.base_url)
      uri.path.presence || "/"
    end

    def package_dependency?(name)
      package_json_path = File.join(repo_path, "package.json")
      return false unless File.exist?(package_json_path)

      package_json = JSON.parse(File.read(package_json_path))
      %w[dependencies devDependencies].any? do |key|
        package_json.fetch(key, {}).key?(name)
      end
    rescue JSON::ParserError
      false
    end

    def repo_seed_configured?
      config_path = Screenshots::ConfigParser.config_path_for(project:, repo_path:)
      return false unless File.file?(config_path)

      parsed = Psych.safe_load(File.read(config_path), aliases: false)
      parsed.is_a?(Hash) && parsed["seed"].present?
    rescue StandardError
      false
    end

    def cleanup_services!
      return if @service_container_ids.empty?

      ServiceContainer.where(id: @service_container_ids).find_each do |service_container|
        service_container.with_lock do
          next unless service_container.capacity_inflight_agent_run_count.zero?

          docker = Containers.backend.get_container(service_container.docker_container_id)
          Containers.backend.stop_container(docker, timeout: 10)
          Containers.backend.delete_container(docker, force: true, v: true)
          service_container.update!(status: "stopped", docker_container_id: nil)
        end
      rescue Docker::Error::DockerError => e
        logger.warn(message: "previews.provision.services_cleanup_failed", agent_run_id: agent_run.id, service_container: service_container.name, error: e.message)
      rescue StandardError => e
        logger.warn(message: "previews.provision.services_cleanup_failed", agent_run_id: agent_run.id, error: e.message)
      end
    end

    def read_file(relative_path)
      path = File.join(repo_path, relative_path)
      File.exist?(path) ? File.read(path) : ""
    end

    def execute_seed_in_container(env)
      result = container_service.execute(
        "bin/rails runner #{Shellwords.escape(Screenshots::SeedRunner::SCRIPT)}",
        timeout: PROVISION_TIMEOUT_SECONDS,
        env: preview_env.merge(env),
        stream: false
      )

      [ result[:stdout].to_s, result[:stderr].to_s, result.success? ]
    end

    def prepare_phoenix_preview_config!
      dev_config_path = File.join(repo_path, "config/dev.exs")
      return unless File.exist?(dev_config_path)

      override_path = File.join(repo_path, PHOENIX_PREVIEW_CONFIG_PATH)
      File.write(override_path, phoenix_preview_config)

      import_line = %(import_config "paid_preview.exs")
      current = File.read(dev_config_path)
      return if current.include?(import_line)

      File.write(dev_config_path, "#{current.rstrip}\n\n#{import_line}\n")
    end

    def phoenix_preview_config
      <<~ELIXIR
        import Config

        app = Mix.Project.config()[:app]
        port = String.to_integer(System.get_env("PORT") || "4000")

        for {key, value} <- Application.get_all_env(app),
            is_atom(key),
            is_list(value),
            String.ends_with?(Atom.to_string(key), "Endpoint") or Keyword.has_key?(value, :http) do
          http =
            value
            |> Keyword.get(:http, [])
            |> Keyword.put(:ip, {0, 0, 0, 0})
            |> Keyword.put(:port, port)

          config app, key,
            value
            |> Keyword.put(:http, http)
            |> Keyword.put(:server, true)
        end
      ELIXIR
    end

    def update_preview_session!(attributes)
      return unless preview_session&.respond_to?(:update!)

      preview_session.update!(attributes)
    end
  end
end
