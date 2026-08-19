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
  let(:preview_provision) do
    instance_double(
      Previews::Provision,
      prepare_workspace!: true,
      boot!: true,
      framework_key: "rails",
      container_service: instance_double(Containers::Provision),
      network_name: "paid-test",
      config: config,
      service_environment: {},
      cleanup!: true
    )
  end
  let(:storage) { instance_double(Screenshots::Storage) }

  before do
    allow(Screenshots::Storage).to receive(:configured?).and_return(false)
    allow(service).to receive(:with_workspace).and_yield(Dir.mktmpdir("screenshots-spec"))
    allow(Previews::Provision).to receive(:new).and_return(preview_provision)
    allow(Screenshots::PrComment).to receive(:call)
    allow(Screenshots::DeriveHints).to receive(:call).and_return({})
    allow(Screenshots::ConfigParser).to receive(:ui_detection_overrides).and_return({})
    allow(service).to receive_messages(
      fetch_changed_files: [ "app/views/home/index.html.erb" ],
      detect_ui_files: [ "app/views/home/index.html.erb" ],
      run_capture!: []
    )
    allow(service).to receive(:start_chrome!)
    allow(service).to receive(:cleanup!)
    allow(project).to receive(:update!).and_call_original
  end

  it "boots screenshots through the shared preview provisioner without starting a tunnel" do
    service.call

    expect(preview_provision).to have_received(:prepare_workspace!)
    expect(preview_provision).to have_received(:boot!).with(start_tunnel: false, allow_seed: true)
  end

  it "skips before container provisioning when precheck detects no UI changes" do
    allow(service).to receive(:detect_ui_files).and_return([])

    result = service.call

    expect(result.status).to eq("no_ui_changes")
    expect(preview_provision).not_to have_received(:prepare_workspace!)
    expect(project.reload.effective_screenshot_status["last_capture_status"]).to eq("no_ui_changes")
    expect(Screenshots::PrComment).to have_received(:call).with(
      hash_including(
        repo: project.full_name,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha,
        screenshots: [],
        status: "no_ui_changes"
      )
    )
  end

  it "refreshes the PR comment when capture fails" do
    allow(preview_provision).to receive(:boot!).and_raise("boom")

    result = service.call

    expect(result.status).to eq("capture_failed")
    expect(Screenshots::PrComment).to have_received(:call).with(
      hash_including(
        repo: project.full_name,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha,
        screenshots: [],
        status: "capture_failed"
      )
    )
  end

  it "rejects unsupported screenshot drivers with a config error" do
    cuprite_config = Screenshots::Configuration.from_hash(
      "driver" => "cuprite",
      "base_url" => "http://localhost:3000",
      "routes" => [ { "path" => "/", "name" => "home" } ]
    )
    allow(preview_provision).to receive(:config).and_return(cuprite_config)

    result = service.call

    expect(result.status).to eq("config_error")
    expect(result.error).to include("cuprite")
  end

  it "rejects seed configuration for Phoenix projects with a config error" do
    allow(preview_provision).to receive(:framework_key).and_return("phoenix")
    service.instance_variable_set(:@preview_provision, preview_provision)
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
    it "starts and stops Playwright tracing for each route" do
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
      tmpdir = Dir.mktmpdir("screenshots-video")
      service.instance_variable_set(:@tmpdir, tmpdir)
      video_path = File.join(tmpdir, Screenshots::ContainerCapture::OUTPUT_DIR, "videos", "capture.webm")
      FileUtils.mkdir_p(File.dirname(video_path))
      File.write(video_path, "webm")

      expect(service.send(:collected_video_path)).to eq(video_path)
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end

  describe "#collected_trace_path" do
    it "falls back to a per-route trace archive when no top-level trace.zip exists" do
      tmpdir = Dir.mktmpdir("screenshots-trace")
      service.instance_variable_set(:@tmpdir, tmpdir)
      route_trace_path = File.join(tmpdir, Screenshots::ContainerCapture::OUTPUT_DIR, "home.trace.zip")
      FileUtils.mkdir_p(File.dirname(route_trace_path))
      File.write(route_trace_path, "trace")

      expect(service.send(:collected_trace_path)).to eq(route_trace_path)
    ensure
      FileUtils.rm_rf(tmpdir)
    end
  end

  describe "#publish_result!" do
    def build_publish_artifacts
      tmpdir = Dir.mktmpdir("screenshots-publish")
      output_dir = File.join(tmpdir, Screenshots::ContainerCapture::OUTPUT_DIR)
      screenshot_path = File.join(output_dir, "home.png")
      route_trace_path = File.join(output_dir, "home.trace.zip")
      video_path = File.join(output_dir, "videos", "capture.webm")

      FileUtils.mkdir_p(File.dirname(video_path))
      File.write(screenshot_path, "png")
      File.write(route_trace_path, "route trace")
      File.write(video_path, "webm")

      {
        tmpdir: tmpdir,
        screenshot_path: screenshot_path,
        route_trace_path: route_trace_path,
        video_path: video_path
      }
    end

    def expect_uploaded_supporting_artifacts(storage:, artifacts:)
      expect(storage).to have_received(:upload_trace).with(
        file_path: artifacts[:route_trace_path],
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha
      )
      expect(storage).to have_received(:upload_video).with(
        file_path: artifacts[:video_path],
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha
      )
      expect(Screenshots::TraceArtifactExporter).to have_received(:call).with(
        hash_including(
          route_name: "home",
          trace_path: artifacts[:route_trace_path],
          log_message: "screenshots.export_failed"
        )
      )
    end

    let(:artifacts) { build_publish_artifacts }
    let(:expected_screenshot_artifact) do
      hash_including(
        "kind" => "screenshot",
        "content_type" => "image/png",
        "locator" => {
          "key" => "screenshots/#{project.owner}/#{project.repo}/pr-#{agent_run.pull_request_number}/#{agent_run.result_commit_sha}/home.png",
          "url" => "https://example.test/home.png"
        },
        "context" => {
          "account_id" => project.account_id,
          "project_id" => project.id,
          "agent_run_id" => agent_run.id
        }
      )
    end
    let(:expected_trace_artifact) do
      hash_including(
        "kind" => "playwright_trace",
        "content_type" => "application/zip",
        "locator" => {
          "key" => "screenshots/#{project.owner}/#{project.repo}/pr-#{agent_run.pull_request_number}/#{agent_run.result_commit_sha}/trace.zip",
          "url" => "https://example.test/trace.zip"
        }
      )
    end
    let(:expected_capture_video_artifact) do
      hash_including(
        "kind" => "capture_video",
        "content_type" => "video/webm",
        "locator" => {
          "key" => "screenshots/#{project.owner}/#{project.repo}/pr-#{agent_run.pull_request_number}/#{agent_run.result_commit_sha}/capture.webm",
          "url" => "https://example.test/capture.webm"
        }
      )
    end

    before do
      allow(service).to receive(:publish_result!).and_call_original
      service.instance_variable_set(:@tmpdir, artifacts[:tmpdir])
      service.instance_variable_set(:@hints, { "home" => { "summary" => "Updated hero" } })
      service.instance_variable_set(:@trace_path, artifacts[:route_trace_path])
      service.instance_variable_set(:@video_path, artifacts[:video_path])
      allow(Screenshots::Storage).to receive_messages(
        configured?: true,
        new: storage
      )
      allow(storage).to receive_messages(
        configured?: true,
        object_key: "screenshots/#{project.owner}/#{project.repo}/pr-#{agent_run.pull_request_number}/#{agent_run.result_commit_sha}/home.png",
        trace_object_key: "screenshots/#{project.owner}/#{project.repo}/pr-#{agent_run.pull_request_number}/#{agent_run.result_commit_sha}/trace.zip",
        video_object_key: "screenshots/#{project.owner}/#{project.repo}/pr-#{agent_run.pull_request_number}/#{agent_run.result_commit_sha}/capture.webm",
        upload: "https://example.test/home.png",
        upload_trace: "https://example.test/trace.zip",
        upload_video: "https://example.test/capture.webm",
        previous_artifacts: { "home" => { png: "https://example.test/previous-home.png" } }
      )
      allow(Screenshots::TraceArtifactExporter).to receive(:call).and_return(
        gif_url: "https://example.test/home.gif",
        video_url: "https://example.test/home.webm",
        video_filename: "home-demo.webm",
        gif_artifact: {
          "kind" => "trace_gif",
          "content_type" => "image/gif",
          "locator" => {
            "key" => "screenshots/#{project.owner}/#{project.repo}/pr-#{agent_run.pull_request_number}/#{agent_run.result_commit_sha}/home.gif",
            "url" => "https://example.test/home.gif"
          },
          "metadata" => {
            "route_name" => "home",
            "filename" => "home.gif"
          }
        },
        video_artifact: {
          "kind" => "trace_video",
          "content_type" => "video/webm",
          "locator" => {
            "key" => "screenshots/#{project.owner}/#{project.repo}/pr-#{agent_run.pull_request_number}/#{agent_run.result_commit_sha}/home.webm",
            "url" => "https://example.test/home.webm"
          },
          "metadata" => {
            "route_name" => "home",
            "filename" => "home.webm"
          }
        }
      )
    end

    after do
      FileUtils.rm_rf(artifacts[:tmpdir])
    end

    it "uploads screenshots, route artifacts, and the selected trace asset" do
      service.send(:publish_result!, [ artifacts[:screenshot_path] ])

      expect(storage).to have_received(:upload).with(
        file_path: artifacts[:screenshot_path],
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha,
        route_name: "home"
      )
      expect_uploaded_supporting_artifacts(storage:, artifacts:)
    end

    # @spec CONTAINER-RUNTIME-018
    it "persists a durable artifact manifest keyed by storage key, without presigned URLs" do
      manifest = service.send(:publish_result!, [ artifacts[:screenshot_path] ])

      expect(manifest).to include(expected_screenshot_artifact, expected_trace_artifact, expected_capture_video_artifact)
      persisted = agent_run.reload.external_metadata["artifact_manifest"]
      expect(persisted).to eq(
        manifest.map { |artifact| artifact.merge("locator" => artifact["locator"].except("url")) }
      )
      expect(persisted).to all(include("locator" => hash_excluding("url")))
    end

    it "passes previous screenshots plus trace and video links into the PR comment" do
      service.send(:publish_result!, [ artifacts[:screenshot_path] ])

      expect(Screenshots::PrComment).to have_received(:call).with(
        hash_including(
          commit_sha: agent_run.result_commit_sha,
          previous_screenshots: { "home" => "https://example.test/previous-home.png" },
          trace_url: "https://example.test/trace.zip",
          video_url: "https://example.test/capture.webm",
          screenshots: [
            hash_including(
              route_name: "home",
              summary: "Updated hero",
              url: "https://example.test/home.png",
              gif_url: "https://example.test/home.gif",
              video_url: "https://example.test/home.webm",
              video_filename: "home-demo.webm"
            )
          ]
        )
      )
    end

    it "still posts the comment when trace and video uploads fail" do
      allow(storage).to receive(:upload_trace).and_raise(Screenshots::Storage::StorageError, "boom")
      allow(storage).to receive(:upload_video).and_raise(Screenshots::Storage::StorageError, "boom")

      expect { service.send(:publish_result!, [ artifacts[:screenshot_path] ]) }.not_to raise_error

      expect(Screenshots::PrComment).to have_received(:call).with(
        hash_including(
          trace_url: nil,
          video_url: nil
        )
      )
    end
  end
end
