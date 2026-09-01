# frozen_string_literal: true

require "docker-api"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"

module Screenshots
  class ContainerCapture
    CHROME_IMAGE = "ghcr.io/browserless/chromium"
    CHROME_ALIAS = "paid-screenshot-browser"
    CHROME_URL = "ws://#{CHROME_ALIAS}:3000"
    OUTPUT_DIR = "tmp/screenshots"
    TRACE_EXTENSION = ".trace.zip"
    TIMING_DOCUMENT = "page-load-timings.json"
    # The timing document is written inside the agent's container. A capture
    # measures a handful of routes, so anything past this is not a document
    # worth parsing into memory.
    MAX_TIMING_DOCUMENT_BYTES = 2 * 1024 * 1024
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
      :artifacts,
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
      @preview_provision = nil
      @screenshot_container = nil
      @chrome_container = nil
      @tmpdir = nil
      @config = nil
      @network = nil
      @published_url = nil
      @artifact_manifest = []
      @hints = {}
      @trace_path = nil
      @video_path = nil
      @page_load_comparisons = []
    end

    def call
      ensure_capture_eligible!

      changed_files = fetch_changed_files
      precheck_ui_files = detect_ui_files(changed_files, nil)
      return finalize_skip("no_ui_changes", changed_files:, ui_files: precheck_ui_files) if precheck_ui_files.empty?

      with_workspace do |repo_path|
        @preview_provision = Previews::Provision.new(
          agent_run:,
          repo_path:,
          logger:
        )
        @preview_provision.prepare_workspace!
        @screenshot_container = @preview_provision.container_service
        @network = @preview_provision.network_name
        @config = @preview_provision.config
        validate_supported_config!

        ui_files = detect_ui_files(changed_files, repo_path)
        return finalize_skip("no_ui_changes", changed_files:, ui_files:) if ui_files.empty?

        @hints = Screenshots::DeriveHints.call(
          agent_run: agent_run,
          routes: @config.routes,
          changed_files: ui_files,
          logger: logger
        )

        start_chrome!
        @preview_provision.boot!(start_tunnel: false, allow_seed: true)
        screenshot_paths = run_capture!(ui_files)
        record_page_load_performance!(changed_files)
        artifact_manifest = publish_result!(screenshot_paths)

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
          artifacts: artifact_manifest,
          published: @published_url.present?,
          screenshots_url: @published_url,
          error: nil
        )
      end
    rescue Screenshots::ConfigError => e
      log_skip("config_error", e.message)
      update_status("config_error")
      Result.new(status: "config_error", changed_files: [], ui_files: [], screenshot_paths: [], artifacts: [], published: false, screenshots_url: nil, error: e.message)
    rescue Containers::Provision::TimeoutError => e
      screenshot_paths = collected_screenshots
      log_skip("capture_timeout", e.message, screenshot_count: screenshot_paths.size)
      refresh_pr_comment("capture_failed")
      update_status("capture_timeout", screenshot_count: screenshot_paths.size)
      Result.new(status: "capture_timeout", changed_files: [], ui_files: [], screenshot_paths: screenshot_paths, artifacts: [], published: false, screenshots_url: nil, error: e.message)
    rescue StandardError => e
      screenshot_paths = collected_screenshots
      log_skip("capture_failed", e.message, error_class: e.class.name, screenshot_count: screenshot_paths.size)
      refresh_pr_comment("capture_failed")
      update_status("capture_failed", screenshot_count: screenshot_paths.size)
      Result.new(status: "capture_failed", changed_files: [], ui_files: [], screenshot_paths: screenshot_paths, artifacts: [], published: false, screenshots_url: nil, error: e.message)
    ensure
      cleanup!
    end

    private

    attr_reader :agent_run, :project, :logger, :config

    SUPPORTED_DRIVERS = %w[playwright].freeze

    def ensure_capture_eligible!
      raise Screenshots::ConfigError, "screenshots are disabled for this project" unless project.screenshots_enabled?
      raise Screenshots::ConfigError, "pull request number is required for screenshot capture" if agent_run.pull_request_number.blank?
      raise Screenshots::ConfigError, "branch name is required for screenshot capture" if agent_run.branch_name.blank?
    end

    def with_workspace
      @tmpdir = Dir.mktmpdir("paid-screenshots-#{agent_run.id}-")
      yield(@tmpdir)
    end

    def validate_supported_config!
      unless config.driver.in?(SUPPORTED_DRIVERS)
        raise Screenshots::ConfigError,
          "container screenshot capture only supports drivers: #{SUPPORTED_DRIVERS.join(', ')} " \
          "(configured: #{config.driver})"
      end

      if phoenix_project? && config.seed.any?
        raise Screenshots::ConfigError,
          "seed configuration is not supported for Phoenix projects yet " \
          "(seeds run via bin/rails runner, which is unavailable in an Elixir/Phoenix repo)"
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
        artifacts: [],
        published: false,
        screenshots_url: nil,
        error: nil
      )
    end

    def record_video?
      project.effective_screenshot_settings["record_video"] == true
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

    def run_capture!(ui_files)
      write_capture_runner
      command = "node .paid-screenshots/capture_runner.mjs"
      env = capture_env.merge(
        "SCREENSHOT_CONFIG_JSON" => screenshot_config_json,
        "SCREENSHOT_OUTPUT_DIR" => OUTPUT_DIR,
        "SCREENSHOT_RECORD_VIDEO" => record_video? ? "1" : "0",
        "SCREENSHOT_SAMPLES" => page_load_samples.to_s,
        "SCREENSHOT_SAMPLE_BUDGET_SECONDS" => page_load_settings.sample_budget_seconds.to_s,
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

      @trace_path = collected_trace_path
      @video_path = collected_video_path
      collected_screenshots
    rescue Containers::Provision::ExecutionError => e
      raise "screenshot capture failed: #{e.message}"
    end

    def page_load_settings
      @page_load_settings ||= PageLoadPerformance::Settings.for(project)
    end

    # Zero samples tells the runner to navigate each route once, exactly as it
    # did before measurement existed.
    # @spec PAGE-LOAD-MEASURE-009
    def page_load_samples
      page_load_settings.enabled? ? page_load_settings.samples : 0
    end

    # Records what the runner measured and evaluates it against the previous
    # capture on this pull request. Measurement never fails the capture: the
    # screenshots are worth publishing either way.
    # @spec PAGE-LOAD-MEASURE-007, PAGE-LOAD-MEASURE-008
    def record_page_load_performance!(changed_files)
      return unless page_load_settings.enabled?

      document = read_timing_document
      return if document.blank?

      measurements = PageLoadPerformance::RecordMeasurements.call(
        agent_run: agent_run,
        document: document,
        viewport: { "width" => config.viewport.width, "height" => config.viewport.height }
      )
      return if measurements.empty?

      @page_load_comparisons = PageLoadPerformance::EvaluateRegressions.call(
        agent_run: agent_run,
        measurements: measurements,
        hints: @hints,
        changed_files: Array(changed_files).map { |file| file.respond_to?(:filename) ? file.filename : file.to_s }
      )
      PageLoadPerformance::ExportLedger.call(project: project)
    rescue StandardError => e
      logger.warn(
        message: "page_load.record_failed",
        project_id: project.id,
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    # @spec PAGE-LOAD-MEASURE-013
    def read_timing_document
      path = File.join(@tmpdir.to_s, OUTPUT_DIR, TIMING_DOCUMENT)
      return nil unless File.exist?(path)

      size = File.size(path)
      if size > MAX_TIMING_DOCUMENT_BYTES
        logger.warn(
          message: "page_load.document_too_large",
          agent_run_id: agent_run.id,
          bytes: size,
          limit: MAX_TIMING_DOCUMENT_BYTES
        )
        return nil
      end

      PageLoadPerformance::TimingDocument.parse(
        JSON.parse(File.read(path)),
        max_samples: [ page_load_settings.samples, 1 ].max
      )
    rescue JSON::ParserError => e
      logger.warn(message: "page_load.document_unparseable", agent_run_id: agent_run.id, error: e.message)
      nil
    end

    def page_load_comment_section
      PageLoadPerformance::CommentSection.call(comparisons: @page_load_comparisons)
    end

    def publish_result!(screenshot_paths)
      return [] if screenshot_paths.empty?
      return [] unless ArtifactStorage.configured?

      storage = Screenshots::Storage.new
      uploaded = screenshot_paths.map { |path| upload_screenshot(storage, path) }
      trace_artifact = upload_trace_artifact(storage)
      video_artifact = upload_video_artifact(storage)

      previous_artifacts = storage.previous_artifacts(
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        exclude_sha: commit_sha
      )

      Screenshots::PrComment.call(
        github_client: project.client,
        repo: project.full_name,
        pr_number: agent_run.pull_request_number,
        commit_sha: commit_sha,
        screenshots: uploaded,
        previous_screenshots: previous_artifacts.transform_values { |formats| formats[:png] }.compact,
        trace_url: trace_artifact&.dig("locator", "url"),
        video_url: video_artifact&.dig("locator", "url"),
        page_load_section: page_load_comment_section
      )

      @published_url = uploaded.first&.fetch(:url, nil)
      @artifact_manifest = build_artifact_manifest(uploaded, trace_artifact:, video_artifact:)
      persist_artifact_manifest!
      @artifact_manifest
    end

    def upload_screenshot(storage, path)
      route_name = File.basename(path, ".png")
      key = storage.object_key(
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: commit_sha,
        route_name: route_name
      )
      screenshot = {
        route_name: route_name,
        summary: @hints.dig(route_name, "summary"),
        artifact: build_artifact_entry(
          kind: "screenshot",
          content_type: Screenshots::Storage::PNG_CONTENT_TYPE,
          key: key,
          url: nil,
          metadata: {
            "route_name" => route_name,
            "filename" => "#{route_name}.png",
            "summary" => @hints.dig(route_name, "summary")
          }
        ),
        url: storage.upload(
          file_path: path,
          org: project.owner,
          repo: project.repo,
          pr_number: agent_run.pull_request_number,
          commit_sha: commit_sha,
          route_name: route_name
        )
      }
      screenshot[:artifact]["locator"]["url"] = screenshot[:url]

      screenshot.merge(
        Screenshots::TraceArtifactExporter.call(
          storage: storage,
          org: project.owner,
          repo: project.repo,
          pr_number: agent_run.pull_request_number,
          commit_sha: commit_sha,
          route_name: route_name,
          trace_path: trace_path_for(path),
          logger: logger,
          log_message: "screenshots.export_failed",
          log_context: {
            project_id: project.id,
            agent_run_id: agent_run.id
          }
        )
      )
    end

    def upload_trace_artifact(storage)
      return nil if @trace_path.blank?

      key = storage.trace_object_key(
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: commit_sha
      )
      url = storage.upload_trace(
        file_path: @trace_path,
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: commit_sha
      )
      build_artifact_entry(
        kind: "playwright_trace",
        content_type: "application/zip",
        key: key,
        url: url,
        metadata: {
          "filename" => "trace.zip",
          "note" => "Playwright trace"
        }
      )
    rescue Screenshots::Storage::StorageError => e
      logger.warn(
        message: "screenshots.trace_upload_failed",
        project_id: project.id,
        agent_run_id: agent_run.id,
        error: e.message
      )
      nil
    end

    def upload_video_artifact(storage)
      return nil if @video_path.blank?

      key = storage.video_object_key(
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: commit_sha
      )
      url = storage.upload_video(
        file_path: @video_path,
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: commit_sha
      )
      build_artifact_entry(
        kind: "capture_video",
        content_type: Screenshots::Storage::WEBM_CONTENT_TYPE,
        key: key,
        url: url,
        metadata: {
          "filename" => "capture.webm"
        }
      )
    rescue Screenshots::Storage::StorageError => e
      logger.warn(
        message: "screenshots.video_upload_failed",
        project_id: project.id,
        agent_run_id: agent_run.id,
        error: e.message
      )
      nil
    end

    def trace_path_for(screenshot_path)
      trace_path = "#{File.dirname(screenshot_path)}/#{File.basename(screenshot_path, '.png')}#{TRACE_EXTENSION}"
      File.exist?(trace_path) ? trace_path : nil
    end

    def write_capture_runner
      runner_dir = File.join(@tmpdir, ".paid-screenshots")
      FileUtils.mkdir_p(runner_dir)
      path = File.join(runner_dir, "capture_runner.mjs")
      File.write(path, capture_runner_script)
      path
    end

    # The capture program that runs inside the preview container. Sampling
    # lives here because only this process holds the browser: it warms up once,
    # samples each route with tracing off, summarizes to a median, records the
    # navigation's status, and isolates timing failures so a route's screenshot
    # still lands.
    # @spec PAGE-LOAD-MEASURE-001, PAGE-LOAD-MEASURE-002, PAGE-LOAD-MEASURE-003,
    # PAGE-LOAD-MEASURE-004, PAGE-LOAD-MEASURE-006, PAGE-LOAD-MEASURE-011
    def capture_runner_script
      <<~JS
        import fs from "fs/promises";

        const playwright = await import("playwright").catch(async () => import("playwright-core"));
        const config = JSON.parse(process.env.SCREENSHOT_CONFIG_JSON);
        const outputDir = process.env.SCREENSHOT_OUTPUT_DIR;
        const recordVideo = process.env.SCREENSHOT_RECORD_VIDEO === "1";
        const samples = Number(process.env.SCREENSHOT_SAMPLES || "0");
        const sampleBudgetMs = Number(process.env.SCREENSHOT_SAMPLE_BUDGET_SECONDS || "0") * 1000;
        const timings = { captured_at: new Date().toISOString(), viewport: config.viewport, routes: {} };
        let samplingStartedAt = null;
        let warmedUp = false;

        await fs.mkdir(outputDir, { recursive: true });

        const browser = await playwright.chromium.connectOverCDP(process.env.CHROME_URL);
        const contextOptions = { viewport: config.viewport };
        if (recordVideo) {
          await fs.mkdir(`${outputDir}/videos`, { recursive: true });
          contextOptions.recordVideo = { dir: `${outputDir}/videos` };
        }
        const context = await browser.newContext(contextOptions);
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

        await authenticate();

        for (const route of config.routes) {
          await measureRoute(route);
          await captureRoute(route);
        }

        if (samples > 0) {
          await fs.writeFile(`${outputDir}/#{TIMING_DOCUMENT}`, JSON.stringify(timings));
        }

        await context.close();
        await browser.close();

        // Timings come from navigations run with tracing off: trace capture
        // inflates load timings unevenly, so measuring under it would make
        // captures incomparable.
        async function collectTiming(target) {
          const response = await page.goto(target, { waitUntil: "networkidle" });
          const entry = await page.evaluate(() => {
            const nav = performance.getEntriesByType("navigation")[0];
            if (!nav) return null;
            // A timing that has not fired yet reads as 0 (loadEventEnd before
            // the load event, for instance). Reporting that as a measurement
            // would poison medians and read as a large improvement next time.
            const ms = (value) => {
              const rounded = Math.round(value);
              return Number.isFinite(rounded) && rounded > 0 ? rounded : null;
            };
            const paint = (name) => {
              const found = performance.getEntriesByType("paint").find((e) => e.name === name);
              return found ? ms(found.startTime) : null;
            };
            const lcpEntries = performance.getEntriesByType("largest-contentful-paint");
            const lcp = lcpEntries.length ? ms(lcpEntries[lcpEntries.length - 1].startTime) : null;
            return {
              ttfb_ms: ms(nav.responseStart),
              dcl_ms: ms(nav.domContentLoadedEventEnd),
              load_ms: ms(nav.loadEventEnd),
              fcp_ms: paint("first-contentful-paint"),
              lcp_ms: lcp,
            };
          });

          return { metrics: entry, status: response ? response.status() : null };
        }

        function summarize(values) {
          const present = values.filter((v) => typeof v === "number" && !Number.isNaN(v));
          if (!present.length) return null;
          const sorted = [...present].sort((a, b) => a - b);
          const middle = Math.floor(sorted.length / 2);
          const median = sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2);
          return { median, min: sorted[0], max: sorted[sorted.length - 1], values: present };
        }

        // The warm-up navigation is discarded: without it, application boot and
        // cold caches land on whichever route the diff happened to put first.
        async function measureRoute(route) {
          if (samples < 1) return;

          const target = new URL(route.path, config.base_url).toString();

          try {
            if (!warmedUp) {
              await page.goto(target, { waitUntil: "networkidle" });
              warmedUp = true;
              samplingStartedAt = Date.now();
            }

            const budgetSpent = sampleBudgetMs > 0 && Date.now() - samplingStartedAt > sampleBudgetMs;
            const attempts = budgetSpent ? 1 : samples;
            const collected = [];
            let status = null;

            for (let i = 0; i < attempts; i += 1) {
              const result = await collectTiming(target);
              status = result.status;
              if (result.metrics) collected.push(result.metrics);
            }

            if (!collected.length) return;

            const metrics = {};
            for (const key of ["ttfb_ms", "dcl_ms", "load_ms", "fcp_ms", "lcp_ms"]) {
              const summary = summarize(collected.map((m) => m[key]));
              if (summary) metrics[key] = summary;
            }

            timings.routes[route.name] = {
              path: new URL(page.url()).pathname,
              http_status: status,
              samples: collected.length,
              metrics,
            };
          } catch (timingError) {
            console.error("timing collection failed:", timingError.message);
          }
        }

        async function captureRoute(route) {
          let tracing = false;
          try {
            await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
            tracing = true;
          } catch (traceError) {
            console.error("trace start failed:", traceError.message);
          }

          try {
            const target = new URL(route.path, config.base_url).toString();
            await page.goto(target, { waitUntil: "networkidle" });
            await annotate(route.annotation);
            await page.screenshot({ path: `${outputDir}/${route.name}.png`, fullPage: true });
          } finally {
            if (tracing) {
              try {
                await context.tracing.stop({ path: `${outputDir}/${route.name}#{TRACE_EXTENSION}` });
              } catch (traceError) {
                console.error("trace stop failed:", traceError.message);
              }
            }
          }
        }
      JS
    end

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

    def capture_env
      @preview_provision.service_environment.merge(
        "CHROME_URL" => CHROME_URL,
        "CI" => "1"
      )
    end

    def phoenix_project?
      resolved_framework == "phoenix"
    end

    def resolved_framework
      @preview_provision&.framework_key || project.detected_framework
    end

    def collected_screenshots
      Dir.glob(File.join(@tmpdir.to_s, OUTPUT_DIR, "*.png")).sort
    end

    def collected_trace_path
      top_level_trace_path || route_trace_paths.first
    end

    def collected_video_path
      Dir.glob(File.join(@tmpdir.to_s, OUTPUT_DIR, "videos", "*.webm")).first
    end

    def top_level_trace_path
      Dir.glob(File.join(@tmpdir.to_s, OUTPUT_DIR, "trace.zip")).first
    end

    def route_trace_paths
      Dir.glob(File.join(@tmpdir.to_s, OUTPUT_DIR, "*#{TRACE_EXTENSION}")).sort
    end

    def commit_sha
      agent_run.result_commit_sha || agent_run.base_commit_sha || agent_run.branch_name
    end

    def build_artifact_manifest(uploaded, trace_artifact:, video_artifact:)
      screenshot_artifacts = uploaded.flat_map do |entry|
        [ entry[:artifact], entry[:gif_artifact], entry[:video_artifact] ]
      end

      # The run's `account_id`/`project_id`/`agent_run_id` are authoritative —
      # they are derived from the run here and from the run in
      # `ExecutionRunners::ExecutionOutputManifest.build_binary_artifact_refs`,
      # so an artifact-supplied context can never misattribute the run.
      (screenshot_artifacts + [ trace_artifact, video_artifact ]).compact.map do |artifact|
        artifact.merge("context" => artifact_context)
      end
    end

    def build_artifact_entry(kind:, content_type:, key:, url:, metadata:)
      {
        "lane" => "object_storage",
        "kind" => kind,
        "content_type" => content_type,
        "locator" => {
          "key" => key,
          "url" => url
        }.compact,
        "context" => artifact_context,
        "metadata" => metadata.compact
      }
    end

    def artifact_context
      {
        "account_id" => project.account_id,
        "project_id" => project.id,
        "agent_run_id" => agent_run.id
      }
    end

    # The persisted manifest is the durable record of the run's artifacts, so
    # each locator carries the storage key only: presigned URLs expire within
    # `ArtifactStorage::MAX_URL_TTL` (the SigV4 one-week cap) and would 403 for
    # any later reader, with no expiry signal to distinguish live from dead.
    # Durable consumers re-sign from the key
    # (`Screenshots::Storage#previous_artifacts` is the established pattern).
    # Live URLs stay on the in-memory `@artifact_manifest` returned via
    # `Result.artifacts`. Uses update_columns to skip lifecycle callbacks and
    # `updated_at` — this is a metadata-only audit record, not a state change
    # (mirrors `AgentRun#persist_prompt_assembly_provenance!`).
    def persist_artifact_manifest!
      current = agent_run.external_metadata.is_a?(Hash) ? agent_run.external_metadata : {}
      metadata = current.deep_dup
      metadata["artifact_manifest"] = @artifact_manifest.map do |artifact|
        artifact.merge("locator" => artifact["locator"]&.except("url"))
      end
      agent_run.update_columns(external_metadata: metadata)
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
        commit_sha: commit_sha,
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

      @preview_provision&.cleanup!
      FileUtils.rm_rf(@tmpdir) if @tmpdir.present?
    end
  end
end
