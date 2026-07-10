# frozen_string_literal: true

require "docker-api"
require "fileutils"
require "json"
require "securerandom"
require "shellwords"
require "tmpdir"
require "uri"

module Screenshots
  class ContainerCapture
    CHROME_IMAGE = "ghcr.io/browserless/chromium"
    CHROME_ALIAS = "paid-screenshot-browser"
    CHROME_URL = "ws://#{CHROME_ALIAS}:3000"
    OUTPUT_DIR = "tmp/screenshots"
    APP_LOG_PATH = "tmp/paid-screenshot-app.log"
    SEED_SCRIPT_PATH = ".paid-screenshots/seed_runner.rb"
    CAPTURE_TIMEOUT_SECONDS = 300
    STARTUP_TIMEOUT_SECONDS = 90
    MEMORY_BYTES = 2 * 1024 * 1024 * 1024
    CPU_QUOTA = 100_000
    PIDS_LIMIT = 300

    Result = Struct.new(
      :status,
      :changed_files,
      :ui_files,
      :screenshot_paths,
      :published,
      :screenshots_url,
      :error,
      keyword_init: true
    ) do
      def success? = status == "captured"
      def skipped? = status != "captured"
    end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, logger: Rails.logger)
      @agent_run = agent_run
      @project = agent_run.project
      @logger = logger
      @service_provisioner = nil
      @screenshot_container = nil
      @chrome_container = nil
      @screenshot_service_container_ids = []
      @screenshot_service_env = {}
      @tmpdir = nil
      @config = nil
      @network = nil
      @published_url = nil
      @hints = {}
    end

    def call
      ensure_capture_eligible!

      # Lightweight precheck: fetch changed files via GitHub API and detect
      # UI-relevant changes *before* paying the Docker/clone/startup cost.
      # The precheck runs without repo context (no custom config overrides),
      # so it may be slightly conservative — that is acceptable.
      changed_files = fetch_changed_files
      precheck_ui_files = detect_ui_files(changed_files, nil)
      return finalize_skip("no_ui_changes", changed_files:, ui_files: precheck_ui_files) if precheck_ui_files.empty?

      with_workspace do |repo_path|
        provision_capture_container(repo_path)
        checkout_branch!
        @config = Screenshots::ConfigParser.from_repo_path(repo_path, project: project)
        validate_supported_config!

        # Re-detect with full repo context (custom patterns/exclusions from config)
        ui_files = detect_ui_files(changed_files, repo_path)
        return finalize_skip("no_ui_changes", changed_files:, ui_files:) if ui_files.empty?

        # Derive per-route hints (best-effort) to scope and annotate capture to the
        # pages the agent actually changed. Empty hints fall back to all routes.
        @hints = Screenshots::DeriveHints.call(
          agent_run: agent_run,
          routes: @config.routes,
          changed_files: ui_files,
          logger: logger
        )

        provision_service_dependencies!
        start_chrome!
        run_setup_commands!
        run_seed!
        start_application!
        screenshot_paths = run_capture!(ui_files)
        publish_result!(screenshot_paths)

        update_status(
          "captured",
          screenshot_count: screenshot_paths.size,
          screenshots_url: @published_url
        )

        Result.new(
          status: "captured",
          changed_files: changed_files,
          ui_files: ui_files,
          screenshot_paths: screenshot_paths,
          published: @published_url.present?,
          screenshots_url: @published_url,
          error: nil
        )
      end
    rescue Screenshots::ConfigError => e
      log_skip("config_error", e.message)
      update_status("config_error")
      Result.new(status: "config_error", changed_files: [], ui_files: [], screenshot_paths: [], published: false, screenshots_url: nil, error: e.message)
    rescue Containers::Provision::TimeoutError => e
      screenshot_paths = collected_screenshots
      log_skip("capture_timeout", e.message, screenshot_count: screenshot_paths.size)
      refresh_pr_comment("capture_failed")
      update_status("capture_timeout", screenshot_count: screenshot_paths.size)
      Result.new(status: "capture_timeout", changed_files: [], ui_files: [], screenshot_paths: screenshot_paths, published: false, screenshots_url: nil, error: e.message)
    rescue StandardError => e
      screenshot_paths = collected_screenshots
      log_skip("capture_failed", e.message, error_class: e.class.name, screenshot_count: screenshot_paths.size)
      refresh_pr_comment("capture_failed")
      update_status("capture_failed", screenshot_count: screenshot_paths.size)
      Result.new(status: "capture_failed", changed_files: [], ui_files: [], screenshot_paths: screenshot_paths, published: false, screenshots_url: nil, error: e.message)
    ensure
      cleanup!
    end

    private

    attr_reader :agent_run, :project, :logger, :config

    def service_provisioner
      @service_provisioner ||= Containers::ServiceProvisioner.new
    end

    def ensure_capture_eligible!
      raise Screenshots::ConfigError, "screenshots are disabled for this project" unless project.screenshots_enabled?
      raise Screenshots::ConfigError, "pull request number is required for screenshot capture" if agent_run.pull_request_number.blank?
      raise Screenshots::ConfigError, "branch name is required for screenshot capture" if agent_run.branch_name.blank?
    end

    def with_workspace
      @tmpdir = Dir.mktmpdir("paid-screenshots-#{agent_run.id}-")
      yield(@tmpdir)
    end

    def provision_capture_container(repo_path)
      @screenshot_container = Containers::Provision.new(
        project: project,
        worktree_path: repo_path,
        memory_bytes: MEMORY_BYTES,
        cpu_quota: CPU_QUOTA,
        pids_limit: PIDS_LIMIT,
        timeout_seconds: CAPTURE_TIMEOUT_SECONDS
      )
      @screenshot_container.provision
      @network = @screenshot_container.network_name
    end

    def checkout_branch!
      git_ops = Containers::GitOperations.new(
        container_service: @screenshot_container,
        agent_run: agent_run
      )
      git_ops.clone_and_checkout_branch(
        branch_name: agent_run.branch_name,
        pull_request_number: agent_run.pull_request_number,
        persist: false
      )
      git_ops.install_artifact_excludes
    end

    SUPPORTED_DRIVERS = %w[playwright].freeze

    def validate_supported_config!
      unless config.driver.in?(SUPPORTED_DRIVERS)
        raise Screenshots::ConfigError,
          "container screenshot capture only supports drivers: #{SUPPORTED_DRIVERS.join(', ')} " \
          "(configured: #{config.driver})"
      end

      dynamic_route = config.routes.find do |route|
        route.path.to_s.match?(/:\w+|%\{[^}]+\}/) || route.seed_key.present?
      end
      return unless dynamic_route

      raise Screenshots::ConfigError, "route #{dynamic_route.name} requires seed interpolation, which is not supported in container capture yet"
    end

    def fetch_changed_files
      project.client.pull_request_files(project.full_name, agent_run.pull_request_number)
    rescue GithubClient::Error => e
      log_skip("fetch_files_failed", e.message)
      []
    end

    def detect_ui_files(changed_files, repo_path)
      overrides = Screenshots::ConfigParser.ui_detection_overrides(project: project, repo_path: repo_path)
      Screenshots::DetectUiChanges.call(changed_files:, repo_path:, **overrides).fetch(:ui_files)
    end

    def finalize_skip(status, changed_files:, ui_files:)
      log_skip(status, "no UI-facing changes detected")
      refresh_pr_comment(status)
      update_status(status)
      Result.new(
        status: status,
        changed_files: changed_files,
        ui_files: ui_files,
        screenshot_paths: [],
        published: false,
        screenshots_url: nil,
        error: nil
      )
    end

    def provision_service_dependencies!
      service_names = configured_service_dependencies
      return if service_names.empty?

      # Snapshot the original service_container_ids and service_environment so
      # we can restore them after provisioning. ServiceProvisioner#provision
      # overwrites both fields, which would orphan the main workflow's service
      # containers and leave stale DATABASE_URL/REDIS_URL pointing at the
      # screenshot network's (now torn-down) services during cleanup.
      original_ids = agent_run.service_container_ids.dup
      original_env = agent_run.service_environment&.deep_dup

      service_provisioner.provision(agent_run, network: @network, service_names: service_names)

      # Capture the screenshot-specific service env for use in capture_env,
      # then restore the agent_run to its original state so the main workflow's
      # service references are not corrupted.
      @screenshot_service_env = agent_run.service_environment&.deep_dup || {}
    ensure
      current_ids = agent_run.service_container_ids
      @screenshot_service_container_ids |= current_ids - (original_ids || current_ids)

      needs_restore = original_ids && (current_ids != original_ids || agent_run.service_environment != original_env)
      if needs_restore
        agent_run.update!(
          service_container_ids: original_ids,
          service_environment: original_env
        )
      end
    end

    def configured_service_dependencies
      db_services = Array(project.effective_screenshot_settings["service_dependencies"])
      (db_services + Array(config.services)).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    def start_chrome!
      @chrome_container = Containers.backend.create_container(
        "Image" => CHROME_IMAGE,
        "name" => "paid-screenshot-chrome-#{agent_run.id}-#{SecureRandom.hex(4)}",
        "HostConfig" => {
          "NetworkMode" => @network,
          "Memory" => 1 * 1024 * 1024 * 1024,
          "MemorySwap" => 1 * 1024 * 1024 * 1024,
          "CpuPeriod" => 100_000,
          "CpuQuota" => 100_000,
          "PidsLimit" => 200
        },
        "NetworkingConfig" => {
          "EndpointsConfig" => {
            @network => {
              "Aliases" => [ CHROME_ALIAS ]
            }
          }
        },
        "Labels" => {
          "paid.screenshot_capture" => "true",
          "paid.agent_run_id" => agent_run.id.to_s
        }
      )
      Containers.backend.start_container(@chrome_container)
    rescue Docker::Error::DockerError => e
      raise Screenshots::ConfigError, "unable to start Chrome service container: #{e.message}"
    end

    def run_setup_commands!
      config.setup_commands.each do |command|
        result = @screenshot_container.execute(command, timeout: CAPTURE_TIMEOUT_SECONDS, env: capture_env, stream: false)
        next if result.success?

        raise "setup command failed: #{command}\n#{result[:stderr].presence || result[:stdout]}"
      end
    end

    # Loads repo-defined seed data (.paid/screenshots.yml) into the per-run
    # isolated database before the application starts. Seed commands run inside
    # the screenshot container via Screenshots::SeedRunner so only repo-defined
    # seeds are used — never production data. No-op when no seed config is
    # present, so capture behavior is unchanged for unseeded repos.
    def run_seed!
      return if config.seed.empty?

      Screenshots::SeedRunner.new.call(
        config: config,
        repo_path: @tmpdir,
        driver_name: config.driver,
        executor: method(:execute_seed_script)
      )
    end

    def execute_seed_script(env)
      write_seed_script
      result = @screenshot_container.execute(
        "bin/rails runner #{Shellwords.escape(SEED_SCRIPT_PATH)}",
        timeout: CAPTURE_TIMEOUT_SECONDS,
        env: capture_env.merge(env),
        stream: false
      )

      [ result[:stdout].to_s, result[:stderr].to_s, result.success? ]
    end

    def write_seed_script
      path = File.join(@tmpdir, SEED_SCRIPT_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, Screenshots::SeedRunner::SCRIPT)
      path
    end

    def start_application!
      command = application_start_command
      raise Screenshots::ConfigError, "could not determine how to start the application for screenshots" if command.blank?

      launch_command = <<~SH
        set -e
        mkdir -p tmp
        (#{command}) > #{Shellwords.escape(APP_LOG_PATH)} 2>&1 &
        echo $! > tmp/paid-screenshot-app.pid
      SH
      @screenshot_container.execute(launch_command, timeout: 30, env: capture_env, stream: false)

      wait_command = readiness_probe_command
      @screenshot_container.execute(
        wait_command,
        timeout: STARTUP_TIMEOUT_SECONDS,
        startup_timeout: STARTUP_TIMEOUT_SECONDS,
        idle_timeout: STARTUP_TIMEOUT_SECONDS,
        env: capture_env,
        stream: false
      )
    rescue Containers::Provision::ExecutionError => e
      app_log = read_file(APP_LOG_PATH)
      raise "application startup failed: #{e.message}\n#{app_log}".strip
    end

    def run_capture!(ui_files)
      write_capture_runner
      command = "node .paid-screenshots/capture_runner.mjs"
      env = capture_env.merge(
        "SCREENSHOT_CONFIG_JSON" => screenshot_config_json,
        "SCREENSHOT_OUTPUT_DIR" => OUTPUT_DIR,
        "CHANGED_FILES" => ui_files.join("\n")
      )

      @screenshot_container.execute(
        command,
        timeout: CAPTURE_TIMEOUT_SECONDS,
        startup_timeout: 30,
        idle_timeout: 60,
        env: env,
        stream: false
      )

      collected_screenshots
    rescue Containers::Provision::ExecutionError => e
      raise "screenshot capture failed: #{e.message}"
    end

    def publish_result!(screenshot_paths)
      return if screenshot_paths.empty?
      return unless Screenshots::Storage.configured?

      storage = Screenshots::Storage.new
      uploaded = screenshot_paths.map do |path|
        route_name = File.basename(path, ".png")
        {
          route_name: route_name,
          summary: @hints.dig(route_name, "summary"),
          url: storage.upload(
            file_path: path,
            org: project.owner,
            repo: project.repo,
            pr_number: agent_run.pull_request_number,
            commit_sha: agent_run.result_commit_sha || agent_run.base_commit_sha || agent_run.branch_name,
            route_name: route_name
          )
        }
      end

      previous = storage.previous_screenshots(
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        exclude_sha: agent_run.result_commit_sha || agent_run.base_commit_sha || agent_run.branch_name
      )

      Screenshots::PrComment.call(
        github_client: project.client,
        repo: project.full_name,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha || agent_run.base_commit_sha || agent_run.branch_name,
        screenshots: uploaded,
        previous_screenshots: previous
      )

      @published_url = uploaded.first&.fetch(:url, nil)
    end

    def write_capture_runner
      runner_dir = File.join(@tmpdir, ".paid-screenshots")
      FileUtils.mkdir_p(runner_dir)
      path = File.join(runner_dir, "capture_runner.mjs")
      File.write(path, capture_runner_script)
      path
    end

    def capture_runner_script
      <<~JS
        import fs from "fs/promises";

        const playwright = await import("playwright").catch(async () => import("playwright-core"));
        const config = JSON.parse(process.env.SCREENSHOT_CONFIG_JSON);
        const outputDir = process.env.SCREENSHOT_OUTPUT_DIR;
        const browser = await playwright.chromium.connectOverCDP(process.env.CHROME_URL);
        const context = browser.contexts()[0] || await browser.newContext({
          viewport: config.viewport,
        });
        const page = await context.newPage();

        async function authenticate() {
          if (!config.auth || config.auth.strategy === "none") return;
          if (config.auth.strategy !== "form") {
            throw new Error(`unsupported auth strategy: ${config.auth.strategy}`);
          }

          await page.goto(new URL(config.auth.login_path || "/", config.base_url).toString(), { waitUntil: "networkidle" });
          for (const [field, selector] of Object.entries(config.auth.fields || {})) {
            if (field === "submit") continue;
            await page.fill(selector, config.auth.credentials[field] || "");
          }
          await Promise.all([
            page.waitForLoadState("networkidle"),
            page.click(config.auth.fields.submit),
          ]);
        }

        async function annotate(annotation) {
          if (!annotation) return;
          await page.evaluate((hint) => {
            if (hint.selector) {
              try {
                const el = document.querySelector(hint.selector);
                if (el) {
                  el.scrollIntoView({ block: "center", inline: "center" });
                  el.style.outline = "3px solid #ff3b30";
                  el.style.outlineOffset = "2px";
                }
              } catch (e) { /* invalid selector — skip highlight */ }
            }
            if (hint.summary) {
              const banner = document.createElement("div");
              banner.textContent = "Changed: " + hint.summary;
              Object.assign(banner.style, {
                position: "fixed", top: "0", left: "0", right: "0", zIndex: "2147483647",
                background: "rgba(255,59,48,0.95)", color: "#fff",
                font: "14px/1.4 system-ui, -apple-system, sans-serif",
                padding: "8px 12px", boxSizing: "border-box",
              });
              document.body.appendChild(banner);
            }
          }, annotation);
        }

        await fs.mkdir(outputDir, { recursive: true });
        await authenticate();

        for (const route of config.routes) {
          const target = new URL(route.path, config.base_url).toString();
          await page.goto(target, { waitUntil: "networkidle" });
          await annotate(route.annotation);
          await page.screenshot({ path: `${outputDir}/${route.name}.png`, fullPage: true });
        }

        await browser.close();
      JS
    end

    # Scopes capture to the routes the agent's change affected, when hints are
    # available. Falls back to every configured route when hints are empty or
    # none of them match a configured route name (conservative — never captures
    # less than the unscoped behavior would when hints are unusable).
    def routes_for_capture
      return config.routes if @hints.blank?

      scoped = config.routes.select { |route| @hints.key?(route.name.to_s) }
      scoped.presence || config.routes
    end

    def screenshot_config_json
      {
        base_url: config.base_url,
        viewport: { width: config.viewport.width, height: config.viewport.height },
        routes: routes_for_capture.map { |route|
          { path: route.path, name: route.name, annotation: @hints[route.name.to_s] }.compact
        },
        auth: {
          strategy: config.auth.strategy,
          login_path: config.auth.login_path,
          fields: config.auth.fields,
          credentials: config.auth.credentials
        }
      }.to_json
    end

    def application_start_command
      port = app_port

      if File.exist?(File.join(@tmpdir, "bin/dev"))
        "PORT=#{port} bin/dev"
      elsif File.exist?(File.join(@tmpdir, "bin/rails"))
        "bundle exec bin/rails server -b 0.0.0.0 -p #{port}"
      elsif File.exist?(File.join(@tmpdir, "mix.exs"))
        "MIX_ENV=dev mix phx.server"
      elsif File.exist?(File.join(@tmpdir, "manage.py"))
        "python3 manage.py runserver 0.0.0.0:#{port}"
      elsif package_dependency?("next")
        "yarn next dev --hostname 0.0.0.0 --port #{port}"
      elsif package_dependency?("vite")
        "yarn vite --host 0.0.0.0 --port #{port}"
      elsif File.exist?(File.join(@tmpdir, "package.json"))
        "yarn dev --host 0.0.0.0 --port #{port}"
      end
    end

    def readiness_probe_command
      uri = URI.parse(config.base_url)
      host = uri.host.presence || "127.0.0.1"
      path = uri.path.presence || "/"
      port = uri.port || app_port

      <<~SH.squish
        SCREENSHOT_APP_HOST=#{Shellwords.escape(host)}
        SCREENSHOT_APP_PORT=#{Shellwords.escape(port.to_s)}
        SCREENSHOT_APP_PATH=#{Shellwords.escape(path)}
        ruby -rnet/http -ruri -e '
          deadline = Time.now + #{STARTUP_TIMEOUT_SECONDS};
          uri = URI("http://\#{ENV.fetch("SCREENSHOT_APP_HOST")}:\#{ENV.fetch("SCREENSHOT_APP_PORT")}\#{ENV.fetch("SCREENSHOT_APP_PATH")}");
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

    def capture_env
      @screenshot_service_env.merge(
        "CHROME_URL" => CHROME_URL,
        "CI" => "1",
        "PORT" => app_port.to_s
      )
    end

    def app_port
      uri = URI.parse(config&.base_url || Screenshots::Configuration::DEFAULT_BASE_URL)
      uri.port || 3000
    end

    def package_dependency?(name)
      package_json_path = File.join(@tmpdir, "package.json")
      return false unless File.exist?(package_json_path)

      package_json = JSON.parse(File.read(package_json_path))
      [ "dependencies", "devDependencies" ].any? do |key|
        package_json.fetch(key, {}).key?(name)
      end
    rescue JSON::ParserError
      false
    end

    def collected_screenshots
      Dir.glob(File.join(@tmpdir.to_s, OUTPUT_DIR, "*.png")).sort
    end

    def read_file(relative_path)
      path = File.join(@tmpdir.to_s, relative_path)
      File.exist?(path) ? File.read(path) : ""
    end

    def update_status(status, screenshot_count: 0, screenshots_url: nil)
      project.update!(
        screenshot_status: project.effective_screenshot_status.merge(
          "last_capture_at" => Time.current.iso8601,
          "last_capture_status" => status,
          "screenshot_count" => screenshot_count,
          "screenshots_url" => screenshots_url
        )
      )
    rescue StandardError => e
      logger.warn(
        message: "screenshots.capture_status_update_failed",
        project_id: project.id,
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    def refresh_pr_comment(status)
      Screenshots::PrComment.call(
        github_client: project.client,
        repo: project.full_name,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha || agent_run.base_commit_sha || agent_run.branch_name,
        screenshots: [],
        status: status
      )
    rescue StandardError => e
      logger.warn(
        message: "screenshots.pr_comment_refresh_failed",
        project_id: project.id,
        agent_run_id: agent_run.id,
        status: status,
        error: e.message
      )
    end

    def log_skip(reason, message, **extra)
      logger.warn(
        {
          message: "screenshots.capture_skipped",
          reason: reason,
          project_id: project.id,
          agent_run_id: agent_run.id,
          error: message
        }.merge(extra)
      )
    end

    def cleanup!
      begin
        Containers.backend.stop_container(@chrome_container, timeout: 0) if @chrome_container
      rescue Docker::Error::DockerError
      end

      begin
        Containers.backend.delete_container(@chrome_container, force: true, v: true) if @chrome_container
      rescue Docker::Error::DockerError => e
        logger.warn(message: "screenshots.chrome_cleanup_failed", agent_run_id: agent_run.id, error: e.message)
      end

      cleanup_screenshot_services!

      begin
        @screenshot_container&.cleanup(force: true)
      rescue StandardError => e
        logger.warn(message: "screenshots.container_cleanup_failed", agent_run_id: agent_run.id, error: e.message)
      end

      FileUtils.rm_rf(@tmpdir) if @tmpdir.present?
    end

    def cleanup_screenshot_services!
      return if @screenshot_service_container_ids.empty?

      ServiceContainer.where(id: @screenshot_service_container_ids).find_each do |sc|
        sc.with_lock do
          next unless sc.capacity_inflight_agent_run_count.zero?

          docker = Containers.backend.get_container(sc.docker_container_id)
          Containers.backend.stop_container(docker, timeout: 10)
          Containers.backend.delete_container(docker, force: true, v: true)
          sc.update!(status: "stopped", docker_container_id: nil)
        end
      rescue Docker::Error::DockerError => e
        logger.warn(message: "screenshots.services_cleanup_failed", agent_run_id: agent_run.id, service_container: sc.name, error: e.message)
      rescue StandardError => e
        logger.warn(message: "screenshots.services_cleanup_failed", agent_run_id: agent_run.id, error: e.message)
      end
    end
  end
end
