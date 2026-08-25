# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::ContainerCapture do
    describe "page load measurement" do
    let(:project) do
      create(:project, screenshot_settings: {
        "enabled" => true,
        "performance" => { "enabled" => true }
      })
    end
    let(:agent_run) do
      create(:agent_run,
        project: project,
        branch_name: "paid/perf",
        pull_request_number: 99,
        result_commit_sha: "abcdef1234567890")
    end
    let(:service) { described_class.new(agent_run: agent_run) }
    let(:config) do
      Screenshots::Configuration.from_hash(
        "base_url" => "http://localhost:3000",
        "routes" => [ { "path" => "/", "name" => "home" } ]
      )
    end
    let(:preview_provision) do
      instance_double(
        Previews::Provision,
        prepare_workspace!: true, boot!: true, framework_key: "rails",
        container_service: instance_double(Containers::Provision),
        network_name: "paid-test", config: config, service_environment: {}, cleanup!: true
      )
    end
    let(:workspace) { Dir.mktmpdir("screenshots-perf-spec") }

    before do
      allow(Screenshots::Storage).to receive(:configured?).and_return(false)
      allow(service).to receive(:with_workspace) do |&block|
        service.instance_variable_set(:@tmpdir, workspace)
        block.call(workspace)
      end
      allow(Previews::Provision).to receive(:new).and_return(preview_provision)
      allow(Screenshots::PrComment).to receive(:call)
      allow(Screenshots::DeriveHints).to receive(:call).and_return({ "home" => { "summary" => "changed home" } })
      allow(Screenshots::ConfigParser).to receive(:ui_detection_overrides).and_return({})
      allow(service).to receive_messages(
        fetch_changed_files: [ "app/views/home/index.html.erb" ],
        detect_ui_files: [ "app/views/home/index.html.erb" ],
        run_capture!: []
      )
      allow(service).to receive(:start_chrome!)
      allow(service).to receive(:cleanup!)
    end

    def write_timing_document(body)
      dir = File.join(workspace, Screenshots::ContainerCapture::OUTPUT_DIR)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "page-load-timings.json"), body)
    end

    def valid_document
      {
        "captured_at" => Time.current.iso8601,
        "viewport" => { "width" => 1280, "height" => 900 },
        "routes" => {
          "home" => {
            "path" => "/", "http_status" => 200, "samples" => 3,
            "metrics" => { "load_ms" => { "median" => 810, "min" => 780, "max" => 903, "values" => [ 780, 810, 903 ] } }
          }
        }
      }.to_json
    end

    # @spec PAGE-LOAD-MEASURE-001
    it "passes the sample count and time budget to the capture runner" do
      allow(service).to receive(:run_capture!).and_call_original
      container = preview_provision.container_service
      allow(container).to receive(:execute)

      service.call

      expect(container).to have_received(:execute).with(
        anything,
        hash_including(env: hash_including("SCREENSHOT_SAMPLES" => "3", "SCREENSHOT_SAMPLE_BUDGET_SECONDS" => anything))
      )
    end

    # @spec PAGE-LOAD-MEASURE-009
    it "tells the runner not to sample when measurement is disabled" do
      project.update!(screenshot_settings: project.screenshot_settings.deep_merge(
        "performance" => { "enabled" => false }
      ))
      allow(service).to receive(:run_capture!).and_call_original
      container = preview_provision.container_service
      allow(container).to receive(:execute)

      service.call

      expect(container).to have_received(:execute).with(
        anything,
        hash_including(env: hash_including("SCREENSHOT_SAMPLES" => "0"))
      )
    end

    # @spec PAGE-LOAD-MEASURE-007
    it "records the timings the runner wrote into the output directory" do
      write_timing_document(valid_document)

      service.call

      measurement = PageLoadMeasurement.sole
      expect(measurement).to have_attributes(
        project_id: project.id, agent_run_id: agent_run.id,
        route_name: "home", load_ms: 810, pull_request_number: 99
      )
    end

    # @spec PAGE-LOAD-MEASURE-008
    it "completes the capture when the timing document is absent" do
      result = service.call

      expect(result.status).to eq("captured")
      expect(PageLoadMeasurement.count).to eq(0)
    end

    # @spec PAGE-LOAD-MEASURE-013
    it "ignores a timing document larger than the size cap" do
      write_timing_document("x" * (Screenshots::ContainerCapture::MAX_TIMING_DOCUMENT_BYTES + 1))

      result = service.call

      expect(result.status).to eq("captured")
      expect(PageLoadMeasurement.count).to eq(0)
    end

    # @spec PAGE-LOAD-MEASURE-013
    it "drops container-reported metrics that are zero or out of range" do
      write_timing_document({
        "captured_at" => Time.current.iso8601,
        "viewport" => { "width" => 1280, "height" => 900 },
        "routes" => {
          "home" => {
            "path" => "/", "http_status" => 200, "samples" => 3,
            "metrics" => {
              "load_ms" => { "median" => 0, "values" => [ 0 ] },
              "lcp_ms" => { "median" => 640, "values" => [ 640 ] }
            }
          }
        }
      }.to_json)

      service.call

      expect(PageLoadMeasurement.sole).to have_attributes(load_ms: nil, lcp_ms: 640)
    end

    # @spec PAGE-LOAD-MEASURE-014
    it "records the viewport from the resolved screenshot config" do
      write_timing_document(valid_document)

      service.call

      expect(PageLoadMeasurement.sole).to have_attributes(viewport_width: 1280, viewport_height: 900)
    end

    # @spec PAGE-LOAD-MEASURE-008
    it "completes the capture when the timing document cannot be parsed" do
      write_timing_document("{not json")

      result = service.call

      expect(result.status).to eq("captured")
      expect(PageLoadMeasurement.count).to eq(0)
    end

    # @spec PAGE-LOAD-REGRESSION-005
    it "evaluates regressions against the previous capture on the pull request" do
      create(:page_load_measurement,
        project: project, pull_request_number: 99, commit_sha: "older111",
        route_name: "home", route_path: "/", lcp_ms: nil, load_ms: 400,
        captured_at: 1.hour.ago)
      write_timing_document(valid_document)

      service.call

      finding = PageLoadRegressionFinding.sole
      expect(finding).to have_attributes(route_name: "home", status: "open", actionable: true)
    end

    # @spec PAGE-LOAD-EXPORT-001
    it "asks the ledger exporter to regenerate the project document after recording" do
      allow(PageLoadPerformance::ExportLedger).to receive(:call)
      write_timing_document(valid_document)

      service.call

      expect(PageLoadPerformance::ExportLedger).to have_received(:call).with(project: project)
    end
  end

  describe "capture runner sampling program" do
    let(:project) { create(:project, screenshot_settings: { "enabled" => true }) }
    let(:agent_run) { create(:agent_run, project: project, branch_name: "paid/perf", pull_request_number: 7) }
    let(:script) { described_class.new(agent_run: agent_run).send(:capture_runner_script) }

    # @spec PAGE-LOAD-MEASURE-002
    it "warms up once per capture rather than once per route" do
      expect(script).to include("if (!warmedUp)")
      expect(script).to include("warmedUp = true")
    end

    # @spec PAGE-LOAD-MEASURE-003
    it "summarizes samples to a median with min, max and the raw values" do
      expect(script).to include("function summarize(")
      expect(script).to include("median")
      expect(script).to include('min: sorted[0]')
      expect(script).to include("values: present")
    end

    # @spec PAGE-LOAD-MEASURE-004
    it "records the navigation's HTTP status alongside the metrics" do
      expect(script).to include("http_status: status")
    end

    # @spec PAGE-LOAD-MEASURE-006
    it "isolates timing failures so the route's screenshot still runs" do
      expect(script).to include('catch (timingError)')
      expect(script).to include("timing collection failed:")
    end

    # @spec PAGE-LOAD-MEASURE-001
    it "measures with tracing off, before the traced screenshot navigation" do
      expect(script.index("await measureRoute(route)")).to be < script.index("await captureRoute(route)")
      expect(script).not_to match(/tracing\.start[\s\S]{0,200}collectTiming/)
    end

    # @spec PAGE-LOAD-MEASURE-011
    it "falls back to a single navigation once the sampling budget is spent" do
      expect(script).to include("const attempts = budgetSpent ? 1 : samples")
    end
  end
end
