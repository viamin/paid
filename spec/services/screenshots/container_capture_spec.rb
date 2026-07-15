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
      expect(script).to include("context.tracing.stop({ path: `${outputDir}/trace.zip` })")
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

  describe "#publish_result! (trace and video uploads)" do
    before do
      allow(service).to receive(:publish_result!).and_call_original
    end

    def with_artifact_tempfile(prefix, ext)
      file = Tempfile.new([ prefix, ext ])
      file.write("fake #{prefix}")
      file.rewind
      yield file
    ensure
      file&.close
      file&.unlink
    end

    def stubbed_storage(upload_trace: nil, upload_video: nil)
      storage = instance_double(Screenshots::Storage)
      allow(Screenshots::Storage).to receive_messages(configured?: true, new: storage)
      allow(storage).to receive(:upload) { |k| "https://s3.example.com/#{k[:route_name]}.png" }
      stub_artifact(storage, :upload_trace, upload_trace)
      stub_artifact(storage, :upload_video, upload_video)
      allow(storage).to receive(:previous_screenshots).and_return({})
      storage
    end

    def stub_artifact(storage, method, value)
      if value == :raise
        allow(storage).to receive(method).and_raise(Screenshots::Storage::StorageError, "boom")
      else
        allow(storage).to receive(method).and_return(value)
      end
    end

    it "uploads the trace archive and surfaces it in the PR comment" do
      storage = stubbed_storage(upload_trace: "https://s3.example.com/trace.zip")

      with_artifact_tempfile("trace", ".zip") do |trace|
        service.instance_variable_set(:@trace_path, trace.path)
        service.send(:publish_result!, [ "/tmp/screenshots/home.png" ])
        expect(storage).to have_received(:upload_trace).with(
          file_path: trace.path, org: project.owner, repo: project.repo,
          pr_number: agent_run.pull_request_number, commit_sha: agent_run.result_commit_sha
        )
      end

      expect(Screenshots::PrComment).to have_received(:call)
        .with(hash_including(trace_url: "https://s3.example.com/trace.zip"))
    end

    it "still publishes screenshots when the trace upload fails" do
      stubbed_storage(upload_trace: :raise)

      with_artifact_tempfile("trace", ".zip") do |trace|
        service.instance_variable_set(:@trace_path, trace.path)
        expect { service.send(:publish_result!, [ "/tmp/screenshots/home.png" ]) }.not_to raise_error
      end

      expect(Screenshots::PrComment).to have_received(:call).with(hash_including(trace_url: nil))
    end

    it "uploads the recorded video and surfaces it in the PR comment" do
      storage = stubbed_storage(upload_video: "https://s3.example.com/capture.webm")

      with_artifact_tempfile("capture", ".webm") do |video|
        service.instance_variable_set(:@video_path, video.path)
        service.send(:publish_result!, [ "/tmp/screenshots/home.png" ])
        expect(storage).to have_received(:upload_video).with(
          file_path: video.path, org: project.owner, repo: project.repo,
          pr_number: agent_run.pull_request_number, commit_sha: agent_run.result_commit_sha
        )
      end

      expect(Screenshots::PrComment).to have_received(:call)
        .with(hash_including(video_url: "https://s3.example.com/capture.webm"))
    end

    it "still publishes screenshots when the video upload fails" do
      stubbed_storage(upload_video: :raise)

      with_artifact_tempfile("capture", ".webm") do |video|
        service.instance_variable_set(:@video_path, video.path)
        expect { service.send(:publish_result!, [ "/tmp/screenshots/home.png" ]) }.not_to raise_error
      end

      expect(Screenshots::PrComment).to have_received(:call).with(hash_including(video_url: nil))
    end

    it "skips the video upload when no recording was collected" do
      storage = stubbed_storage

      service.instance_variable_set(:@video_path, nil)
      service.send(:publish_result!, [ "/tmp/screenshots/home.png" ])

      expect(storage).not_to have_received(:upload_video)
    end
  end
end
