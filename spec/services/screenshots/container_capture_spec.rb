# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::ContainerCapture do
  let(:project) do
    create(:project, screenshot_settings: {
      "enabled" => true,
      "service_dependencies" => [ "postgres" ]
    })
  end
  let(:agent_run) do
    create(:agent_run,
      project: project,
      branch_name: "paid/test-branch",
      pull_request_number: 99,
      result_commit_sha: "abcdef1234567890")
  end
  let(:service) { described_class.new(agent_run: agent_run) }
  let(:config) do
    Screenshots::Configuration.from_hash(
      "base_url" => "http://localhost:3000",
      "routes" => [ { "path" => "/", "name" => "home" } ],
      "services" => [ "redis" ]
    )
  end

  before do
    allow(Screenshots::Storage).to receive(:configured?).and_return(false)
    allow(service).to receive(:with_workspace).and_yield(Dir.mktmpdir("screenshots-spec"))
    allow(service).to receive(:provision_capture_container) { service.instance_variable_set(:@network, "paid-test") }
    allow(service).to receive(:checkout_branch!)
    allow(Screenshots::PrComment).to receive(:call)
    allow(Screenshots::DeriveHints).to receive(:call).and_return({})
    allow(Screenshots::ConfigParser).to receive_messages(from_repo_path: config, ui_detection_overrides: {})
    allow(service).to receive_messages(
      fetch_changed_files: [ "app/views/home/index.html.erb" ],
      detect_ui_files: [ "app/views/home/index.html.erb" ],
      run_capture!: []
    )
    allow(service).to receive(:start_chrome!)
    allow(service).to receive(:run_setup_commands!)
    allow(service).to receive(:start_application!)
    allow(service).to receive(:publish_result!)
    allow(service).to receive(:cleanup!)
    allow(project).to receive(:update!).and_call_original
    allow(Previews::TunnelManager).to receive_messages(
      allocate_port: 8201,
      wait_until_ready!: true
    )
  end

  it "merges project and repo service dependencies for provisioning" do
    provisioner = instance_double(Containers::ServiceProvisioner, cleanup: true)
    allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
    allow(provisioner).to receive(:provision)

    service.call

    expect(provisioner).to have_received(:provision)
      .with(agent_run, network: "paid-test", service_names: contain_exactly("postgres", "redis"))
  end

  it "skips before container provisioning when precheck detects no UI changes" do
    allow(service).to receive(:detect_ui_files).and_return([])

    result = service.call

    expect(result.status).to eq("no_ui_changes")
    expect(service).not_to have_received(:provision_capture_container)
    expect(project.reload.effective_screenshot_status["last_capture_status"]).to eq("no_ui_changes")
    expect(Screenshots::PrComment).to have_received(:call) do |**args|
      expect(args).to include(
        repo: project.full_name,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha,
        screenshots: [],
        status: "no_ui_changes"
      )
      expect(args[:github_client]).to be_a(GithubClient)
    end
  end

  it "refreshes the PR comment when capture fails" do
    provisioner = instance_double(Containers::ServiceProvisioner, cleanup: true)
    allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
    allow(provisioner).to receive(:provision)
    allow(service).to receive(:start_application!).and_raise("boom")

    result = service.call

    expect(result.status).to eq("capture_failed")
    expect(Screenshots::PrComment).to have_received(:call) do |**args|
      expect(args).to include(
        repo: project.full_name,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha,
        screenshots: [],
        status: "capture_failed"
      )
      expect(args[:github_client]).to be_a(GithubClient)
    end
  end

  it "restores the original service container ids and environment when dependency provisioning fails" do
    provisioner = instance_double(Containers::ServiceProvisioner, cleanup: true)
    allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
    allow(provisioner).to receive(:provision) do
      agent_run.update!(
        service_container_ids: [ 101, 202 ],
        service_environment: { "DATABASE_URL" => "postgres://screenshot-host/db" }
      )
      raise Containers::Provision::TimeoutError, "timed out"
    end

    result = service.call

    expect(result.status).to eq("capture_timeout")
    agent_run.reload
    expect(agent_run.service_container_ids).to eq([])
    expect(agent_run.service_environment).to eq({})
    expect(service.instance_variable_get(:@screenshot_service_container_ids)).to contain_exactly(101, 202)
  end

  it "rejects unsupported screenshot drivers with a config error" do
    cuprite_config = Screenshots::Configuration.from_hash(
      "driver" => "cuprite",
      "base_url" => "http://localhost:3000",
      "routes" => [ { "path" => "/", "name" => "home" } ]
    )
    allow(Screenshots::ConfigParser).to receive(:from_repo_path).and_return(cuprite_config)
    provisioner = instance_double(Containers::ServiceProvisioner, cleanup: true)
    allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

    result = service.call

    expect(result.status).to eq("config_error")
    expect(result.error).to include("cuprite")
  end

  it "shell-escapes readiness probe url parts before building the probe command" do
    allow(service).to receive(:config).and_return(
      Screenshots::Configuration.from_hash(
        "base_url" => "http://localhost:3000/it's-a-path",
        "routes" => [ { "path" => "/", "name" => "home" } ]
      )
    )

    command = service.send(:readiness_probe_command)

    expect(command).to include("SCREENSHOT_APP_HOST=localhost")
    expect(command).to include("SCREENSHOT_APP_PORT=3000")
    expect(command).to include("SCREENSHOT_APP_PATH=/it\\'s-a-path")
    expect(command).to include('ENV.fetch("SCREENSHOT_APP_PATH")')
    expect(command).not_to include(%q(uri = URI("http://localhost:3000/it's-a-path")))
  end

  it "uses Phoenix startup when mix.exs is present and exposes the port in capture env" do
    tmpdir = Dir.mktmpdir("phoenix-screenshot")
    File.write(File.join(tmpdir, "mix.exs"), "defmodule Demo.MixProject do end")
    service.instance_variable_set(:@tmpdir, tmpdir)
    allow(service).to receive(:config).and_return(
      Screenshots::Configuration.from_hash(
        "base_url" => "http://localhost:4100",
        "routes" => [ { "path" => "/", "name" => "home" } ]
      )
    )

    expect(service.send(:application_start_command)).to eq("MIX_ENV=dev mix phx.server")
    expect(service.send(:capture_env).fetch("PORT")).to eq("4100")
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "overrides Phoenix dev endpoint binding to listen on all interfaces during capture" do
    tmpdir = Dir.mktmpdir("phoenix-bind")
    FileUtils.mkdir_p(File.join(tmpdir, "config"))
    File.write(File.join(tmpdir, "mix.exs"), "defmodule Demo.MixProject do end")
    File.write(File.join(tmpdir, "config/dev.exs"), <<~EXS)
      import Config

      config :demo, DemoWeb.Endpoint,
        http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")]
    EXS
    service.instance_variable_set(:@tmpdir, tmpdir)

    service.send(:prepare_phoenix_endpoint_binding!)

    runtime = File.read(File.join(tmpdir, "config/runtime.exs"))
    expect(runtime).to include("config :demo, DemoWeb.Endpoint")
    expect(runtime).to include("http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env(\"PORT\") || \"4000\")]")
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "rejects seed configuration for Phoenix projects with a config error" do
    tmpdir = Dir.mktmpdir("phoenix-seed")
    File.write(File.join(tmpdir, "mix.exs"), "defmodule Demo.MixProject do end")
    service.instance_variable_set(:@tmpdir, tmpdir)
    allow(service).to receive(:config).and_return(
      Screenshots::Configuration.from_hash(
        "base_url" => "http://localhost:4100",
        "routes" => [ { "path" => "/", "name" => "home" } ],
        "seed" => [ { "key" => "__all__", "runner" => "Screenshots::SeedData::Paid.call" } ]
      )
    )

    expect { service.send(:validate_supported_config!) }.to raise_error(
      Screenshots::ConfigError, /not supported for Phoenix projects yet/
    )
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "allows seedless Phoenix captures through config validation" do
    tmpdir = Dir.mktmpdir("phoenix-noseed")
    File.write(File.join(tmpdir, "mix.exs"), "defmodule Demo.MixProject do end")
    service.instance_variable_set(:@tmpdir, tmpdir)
    allow(service).to receive(:config).and_return(
      Screenshots::Configuration.from_hash(
        "base_url" => "http://localhost:4100",
        "routes" => [ { "path" => "/", "name" => "home" } ]
      )
    )

    expect { service.send(:validate_supported_config!) }.not_to raise_error
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  describe "#provision_capture_container" do
    it "reserves a preview tunnel port and passes it into container provisioning" do
      fresh_service = described_class.new(agent_run: agent_run)
      provision = instance_double(Containers::Provision, provision: true, network_name: "paid-test")
      allow(Containers::Provision).to receive(:new).and_return(provision)

      fresh_service.send(:provision_capture_container, "/tmp/repo")

      expect(Previews::TunnelManager).to have_received(:allocate_port).with(key: "screenshots-agent-run-#{agent_run.id}")
      expect(Containers::Provision).to have_received(:new).with(
        project: project,
        worktree_path: "/tmp/repo",
        memory_bytes: described_class::MEMORY_BYTES,
        cpu_quota: described_class::CPU_QUOTA,
        pids_limit: described_class::PIDS_LIMIT,
        timeout_seconds: described_class::CAPTURE_TIMEOUT_SECONDS,
        preview_tunnel: have_attributes(
          session_token: "screenshots-agent-run-#{agent_run.id}",
          tunnel_port: 8201,
          app_port: nil
        )
      )
    end
  end

  describe "#start_application!" do
    def build_started_capture_service(target_service:, tmpdir:, config:, tunnel_port:)
      target_service.instance_variable_set(:@tmpdir, tmpdir)
      target_service.instance_variable_set(:@config, config)
      target_service.instance_variable_set(:@preview_tunnel,
        Previews::TunnelManager::TunnelDefinition.new(
          session_token: "screenshots-agent-run-#{agent_run.id}",
          tunnel_port: tunnel_port,
          app_port: nil
        ))
      provision = instance_double(Containers::Provision)
      target_service.instance_variable_set(:@screenshot_container, provision)
      allow(provision).to receive(:activate_preview_tunnel!)
      allow(provision).to receive(:execute).and_return(double(success?: true, :[] => nil))
      allow(target_service).to receive_messages(
        readiness_probe_command: "echo ready",
        application_start_command: "bin/dev"
      )
      provision
    end

    it "activates the preview tunnel after config parsing and waits for it to come up" do
      fresh_service = described_class.new(agent_run: agent_run)
      tmpdir = Dir.mktmpdir("screenshot-start")
      provision = build_started_capture_service(target_service: fresh_service, tmpdir:, config:, tunnel_port: 8201)

      fresh_service.send(:start_application!)

      expect(provision).to have_received(:activate_preview_tunnel!).with(app_port: 3000)
      expect(Previews::TunnelManager).to have_received(:wait_until_ready!).with(port: 8201, path: "/")
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end

  describe "#screenshot_config_json (capture scoping and annotation)" do
    let(:multi_route_config) do
      Screenshots::Configuration.from_hash(
        "base_url" => "http://localhost:3000",
        "routes" => [
          { "path" => "/dashboard", "name" => "dashboard" },
          { "path" => "/settings", "name" => "settings" }
        ]
      )
    end

    before { allow(service).to receive(:config).and_return(multi_route_config) }

    it "captures every configured route when there are no hints" do
      routes = JSON.parse(service.send(:screenshot_config_json)).fetch("routes")

      expect(routes.map { |r| r["name"] }).to contain_exactly("dashboard", "settings")
      expect(routes).to all(satisfy { |r| !r.key?("annotation") })
    end

    it "scopes capture to hinted routes and attaches their annotations" do
      service.instance_variable_set(:@hints, {
        "dashboard" => { "summary" => "New cost card", "selector" => "[data-testid='cost']" }
      })

      routes = JSON.parse(service.send(:screenshot_config_json)).fetch("routes")

      expect(routes.map { |r| r["name"] }).to eq([ "dashboard" ])
      expect(routes.first["annotation"]).to eq(
        "summary" => "New cost card", "selector" => "[data-testid='cost']"
      )
    end

    it "falls back to all routes when hints match no configured route" do
      service.instance_variable_set(:@hints, { "nonexistent" => { "summary" => "x" } })

      routes = JSON.parse(service.send(:screenshot_config_json)).fetch("routes")

      expect(routes.map { |r| r["name"] }).to contain_exactly("dashboard", "settings")
    end
  end

  describe "#capture_runner_script (trace recording)" do
    it "starts and stops Playwright tracing, writing trace.zip" do
      script = service.send(:capture_runner_script)

      expect(script).to include("context.tracing.start({ screenshots: true, snapshots: true, sources: true })")
      expect(script).to include("context.tracing.stop({ path: `${outputDir}/${route.name}.trace.zip` })")
    end

    it "gates video recording on the SCREENSHOT_RECORD_VIDEO env var" do
      script = service.send(:capture_runner_script)

      expect(script).to include('process.env.SCREENSHOT_RECORD_VIDEO === "1"')
      expect(script).to include("contextOptions.recordVideo = { dir: `${outputDir}/videos` }")
    end

    it "closes the context before the browser so recorded videos flush to disk" do
      script = service.send(:capture_runner_script)

      context_close_index = script.index("await context.close();")
      browser_close_index = script.index("await browser.close();")

      expect(context_close_index).not_to be_nil
      expect(browser_close_index).to be > context_close_index
    end
  end

  describe "#record_video?" do
    it "defaults to disabled" do
      expect(service.send(:record_video?)).to be false
    end

    it "reflects the project record_video screenshot setting" do
      allow(project).to receive(:effective_screenshot_settings)
        .and_return("record_video" => true)

      expect(service.send(:record_video?)).to be true
    end
  end

  describe "#collected_video_path" do
    it "globs the recorded .webm from the videos subdirectory" do
      tmpdir = service.instance_variable_get(:@tmpdir) || Dir.mktmpdir("screenshots-spec")
      service.instance_variable_set(:@tmpdir, tmpdir)
      videos_dir = File.join(tmpdir, Screenshots::ContainerCapture::OUTPUT_DIR, "videos")
      FileUtils.mkdir_p(videos_dir)
      written = File.join(videos_dir, "abc.webm")
      File.write(written, "fake video")

      expect(service.send(:collected_video_path)).to eq(written)
    ensure
      FileUtils.rm_rf(tmpdir)
    end

    it "returns nil when no video was recorded" do
      tmpdir = Dir.mktmpdir("screenshots-spec")
      service.instance_variable_set(:@tmpdir, tmpdir)

      expect(service.send(:collected_video_path)).to be_nil
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end

  describe "seed data support" do
    let(:seed_config) do
      Screenshots::Configuration.from_hash(
        "base_url" => "http://localhost:3000",
        "routes" => [ { "path" => "/", "name" => "home" } ],
        "seed" => [ { "key" => "__all__", "runner" => "Screenshots::SeedData::Paid.call" } ]
      )
    end
    let(:workspace) { Dir.mktmpdir("seed-spec") }
    let(:container) do
      instance_double(Containers::Provision).tap do |c|
        allow(c).to receive(:execute).and_return(
          Containers::Provision::Result.success(stdout: "{}", stderr: "", exit_code: 0)
        )
      end
    end

    before do
      allow(service).to receive(:config).and_return(seed_config)
      service.instance_variable_set(:@tmpdir, workspace)
      service.instance_variable_set(:@screenshot_container, container)
      service.instance_variable_set(:@screenshot_service_env, { "DATABASE_URL" => "postgres://isolated/db" })
    end

    after do
      FileUtils.rm_rf(workspace)
    end

    it "runs the seed script inside the container with the isolated database env" do
      captured_command = nil
      captured_env = nil
      allow(container).to receive(:execute) do |command, **opts|
        captured_command = command
        captured_env = opts[:env]
        Containers::Provision::Result.success(stdout: "{}", stderr: "", exit_code: 0)
      end

      service.send(:run_seed!)

      expect(captured_command).to eq("bin/rails runner .paid-screenshots/seed_runner.rb")
      expect(captured_env).to include(
        "DATABASE_URL" => "postgres://isolated/db",
        "CHROME_URL" => described_class::CHROME_URL
      )
      expect(captured_env).to have_key("SCREENSHOT_SEED_CONFIG")
    end

    it "writes the Screenshots::SeedRunner script into the workspace" do
      service.send(:run_seed!)

      written = File.read(File.join(workspace, ".paid-screenshots/seed_runner.rb"))
      expect(written).to eq(Screenshots::SeedRunner::SCRIPT)
    end

    it "is a no-op when no seed config is present" do
      allow(service).to receive(:config).and_return(
        Screenshots::Configuration.from_hash(
          "base_url" => "http://localhost:3000",
          "routes" => [ { "path" => "/", "name" => "home" } ]
        )
      )

      service.send(:run_seed!)

      expect(container).not_to have_received(:execute)
    end

    it "raises when the seed script exits non-zero" do
      allow(container).to receive(:execute).and_return(
        Containers::Provision::Result.new(success: false, data: { stdout: "", stderr: "seed blew up" })
      )

      expect { service.send(:run_seed!) }.to raise_error(/Screenshot seed setup failed: seed blew up/)
    end

    it "loads seed data before the app readiness check, failing the capture on seed error" do
      allow(container).to receive(:execute).and_return(
        Containers::Provision::Result.new(success: false, data: { stdout: "", stderr: "seed blew up" })
      )
      allow(service).to receive(:provision_service_dependencies!) do
        service.instance_variable_set(:@screenshot_service_env, { "DATABASE_URL" => "postgres://isolated/db" })
      end
      allow(Screenshots::ConfigParser).to receive_messages(from_repo_path: seed_config, ui_detection_overrides: {})
      allow(service).to receive_messages(start_chrome!: true, run_setup_commands!: true,
        publish_result!: true, cleanup!: true, run_capture!: [])
      allow(service).to receive(:start_application!)

      result = service.call

      expect(result.status).to eq("capture_failed")
      expect(result.error).to include("seed blew up")
      expect(service).not_to have_received(:start_application!)
    end
  end

  describe "#publish_result!" do
    let(:storage) { instance_double(Screenshots::Storage) }
    let(:screenshot_paths) { [ "/tmp/screenshots/home.png" ] }
    let(:uploaded_screenshot) do
      {
        route_name: "home",
        summary: "Updated hero",
        url: "https://s3.example.com/home.png"
      }
    end

    before do
      allow(service).to receive(:publish_result!).and_call_original
      service.instance_variable_set(:@hints, { "home" => { "summary" => "Updated hero" } })
      allow(Screenshots::Storage).to receive_messages(
        configured?: true,
        new: storage
      )
      allow(storage).to receive_messages(
        upload: "https://s3.example.com/home.png",
        previous_artifacts: { "home" => { png: "https://s3.example.com/previous-home.png" } }
      )
      allow(storage).to receive(:upload_artifact)
      allow(Screenshots::TraceArtifactExporter).to receive(:call).and_return({})
    end

    it "delegates trace artifact export" do
      service.send(:publish_result!, screenshot_paths)

      expect(storage).to have_received(:upload) do |**args|
        expect(args).to include(file_path: "/tmp/screenshots/home.png", route_name: "home")
      end
      expect(Screenshots::TraceArtifactExporter).to have_received(:call).with(
        hash_including(
          storage: storage,
          route_name: "home",
          trace_path: nil,
          log_message: "screenshots.export_failed"
        )
      )
      expect(storage).not_to have_received(:upload_artifact)
    end

    it "includes the uploaded screenshot in the PR comment payload" do
      service.send(:publish_result!, screenshot_paths)

      expect(Screenshots::PrComment).to have_received(:call).with(
        hash_including(
          commit_sha: agent_run.result_commit_sha,
          screenshots: [ uploaded_screenshot ],
          previous_screenshots: { "home" => "https://s3.example.com/previous-home.png" }
        )
      )
      expect(service.instance_variable_get(:@published_url)).to eq("https://s3.example.com/home.png")
    end

    it "falls back to static PNG comments when no trace artifacts are exported" do
      allow(Screenshots::TraceArtifactExporter).to receive(:call).and_return({})

      service.send(:publish_result!, screenshot_paths)

      expect(Screenshots::PrComment).to have_received(:call).with(
        hash_including(
          screenshots: [
            {
              route_name: "home",
              summary: "Updated hero",
              url: "https://s3.example.com/home.png"
            }
          ]
        )
      )
    end

    it "passes the sibling Playwright trace path to the exporter when present" do
      dir = Dir.mktmpdir("container-trace-spec")
      paths = [ File.join(dir, "home.png") ]
      File.write(paths.first, "png")
      File.write(File.join(dir, "home.trace.zip"), "fake trace")

      service.send(:publish_result!, paths)

      expect(Screenshots::TraceArtifactExporter).to have_received(:call).with(
        hash_including(
          route_name: "home",
          trace_path: File.join(dir, "home.trace.zip")
        )
      )
    end
  end
end
