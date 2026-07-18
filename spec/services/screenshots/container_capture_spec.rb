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
    allow(service).to receive(:publish_result!)
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
    allow(preview_provision).to receive(:boot!).and_raise("boom")

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

  describe "#publish_result!" do
    let(:tmpdir) { Dir.mktmpdir("screenshots-publish") }
    let(:screenshot_path) { File.join(tmpdir, Screenshots::ContainerCapture::OUTPUT_DIR, "home.png") }
    let(:trace_path) { File.join(tmpdir, Screenshots::ContainerCapture::OUTPUT_DIR, "trace.zip") }
    let(:video_path) { File.join(tmpdir, Screenshots::ContainerCapture::OUTPUT_DIR, "videos", "capture.webm") }

    before do
      allow(service).to receive(:publish_result!).and_call_original
      FileUtils.mkdir_p(File.dirname(screenshot_path))
      FileUtils.mkdir_p(File.dirname(video_path))
      File.write(screenshot_path, "png")
      File.write(trace_path, "zip")
      File.write(video_path, "webm")
      service.instance_variable_set(:@tmpdir, tmpdir)
      service.instance_variable_set(:@hints, { "home" => { "summary" => "Updated hero" } })
      service.instance_variable_set(:@trace_path, trace_path)
      service.instance_variable_set(:@video_path, video_path)
      allow(Screenshots::Storage).to receive_messages(
        configured?: true,
        new: storage
      )
      allow(storage).to receive_messages(
        upload: "https://example.test/home.png",
        upload_trace: "https://example.test/trace.zip",
        upload_video: "https://example.test/capture.webm",
        previous_screenshots: {}
      )
    end

    after do
      FileUtils.rm_rf(tmpdir)
    end

    it "uploads trace and video artifacts and passes their URLs to the PR comment" do
      service.send(:publish_result!, [ screenshot_path ])

      expect(storage).to have_received(:upload_trace).with(
        file_path: trace_path,
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha
      )
      expect(storage).to have_received(:upload_video).with(
        file_path: video_path,
        org: project.owner,
        repo: project.repo,
        pr_number: agent_run.pull_request_number,
        commit_sha: agent_run.result_commit_sha
      )
      expect(Screenshots::PrComment).to have_received(:call).with(hash_including(
        trace_url: "https://example.test/trace.zip",
        video_url: "https://example.test/capture.webm"
      ))
    end

    it "still posts the comment when trace and video uploads fail" do
      allow(storage).to receive(:upload_trace).and_raise(Screenshots::Storage::StorageError, "boom")
      allow(storage).to receive(:upload_video).and_raise(Screenshots::Storage::StorageError, "boom")

      expect { service.send(:publish_result!, [ screenshot_path ]) }.not_to raise_error

      expect(Screenshots::PrComment).to have_received(:call).with(hash_including(
        trace_url: nil,
        video_url: nil
      ))
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

  describe "#capture_runner_script" do
    it "records a Playwright trace and gates video recording on the env flag" do
      script = service.send(:capture_runner_script)

      expect(script).to include('process.env.SCREENSHOT_RECORD_VIDEO === "1"')
      expect(script).to include("context.tracing.start({ screenshots: true, snapshots: true, sources: true })")
      expect(script).to include("context.tracing.stop({ path: `${outputDir}/trace.zip` })")
      expect(script).to include("contextOptions.recordVideo = { dir: `${outputDir}/videos` }")
    end

    it "closes the Playwright context before the browser so videos flush to disk" do
      script = service.send(:capture_runner_script)

      expect(script.index("await context.close();")).to be < script.index("await browser.close();")
    end

    it "stops tracing from a finally block so artifacts still flush on capture errors" do
      script = service.send(:capture_runner_script)

      expect(script).to include("} finally {")
      expect(script.index("await context.tracing.stop({ path: `${outputDir}/trace.zip` });"))
        .to be > script.index("} finally {")
    end
  end

  describe "#record_video?" do
    it "defaults to disabled" do
      expect(service.send(:record_video?)).to be false
    end

    it "uses the legacy project screenshot setting" do
      project.update!(screenshot_settings: project.screenshot_settings.merge("record_video" => true))

      expect(service.send(:record_video?)).to be true
    end
  end

  describe "#collected_video_path" do
    it "returns the recorded webm path when present" do
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
end
