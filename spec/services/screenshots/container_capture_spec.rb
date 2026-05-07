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

  it "marks the project status when capture is skipped for non-UI changes" do
    allow(service).to receive(:detect_ui_files).and_return([])
    allow(Containers::ServiceProvisioner).to receive(:new).and_return(instance_double(Containers::ServiceProvisioner, cleanup: true))

    result = service.call

    expect(result.status).to eq("no_ui_changes")
    expect(project.reload.effective_screenshot_status["last_capture_status"]).to eq("no_ui_changes")
  end
end
