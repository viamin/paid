# frozen_string_literal: true

require "rails_helper"
require "screenshots/capture"

RSpec.describe Screenshots::Capture do
  let(:session) { instance_double(Capybara::Session, current_path: "/projects/1") }
  let(:driver) { instance_double(Capybara::Cuprite::Driver, quit: true) }
  let(:seed_data) { { user: instance_double(User), project: instance_double(Project, id: 1) } }
  let(:output_dir) { Dir.mktmpdir }
  let(:target) do
    Screenshots::CaptureTargets::Target.new(
      slug: "project_show",
      path_builder: "/projects/1",
      requires_auth: true
    )
  end

  before do
    allow(Capybara::Session).to receive(:new).with(:paid_screenshots).and_return(session)
    allow(session).to receive_messages(driver: driver, has_no_css?: true)
    allow(session).to receive(:visit)
    allow(session).to receive(:save_screenshot)
    allow(Screenshots::CaptureTargets).to receive(:call).and_return([ target ])
  end

  after do
    FileUtils.rm_rf(output_dir)
  end

  around do |example|
    original_chrome_url = ENV["CHROME_URL"]
    original_app_host = ENV["CAPYBARA_APP_HOST"]
    example.run
  ensure
    ENV["CHROME_URL"] = original_chrome_url
    ENV["CAPYBARA_APP_HOST"] = original_app_host
  end

  it "passes changed files into target resolution" do
    capture = described_class.new(output_dir: output_dir, changed_files: [ "app/views/projects/show.html.erb" ])
    allow(capture).to receive(:register_driver)
    allow(capture).to receive(:setup_capybara)
    allow(capture).to receive(:ensure_seed_data!).and_return(seed_data)
    allow(capture).to receive(:sign_in)

    capture.call

    expect(Screenshots::CaptureTargets).to have_received(:call).with(
      changed_files: [ "app/views/projects/show.html.erb" ]
    )
  end

  it "raises when any mapped target fails to capture" do
    capture = described_class.new(output_dir: output_dir, changed_files: [ "app/views/projects/show.html.erb" ])
    allow(capture).to receive(:register_driver)
    allow(capture).to receive(:setup_capybara)
    allow(capture).to receive(:ensure_seed_data!).and_return(seed_data)
    allow(capture).to receive(:sign_in)
    allow(session).to receive(:visit).and_raise(StandardError, "boom")

    expect { capture.call }.to raise_error(RuntimeError, /project_show .* boom/)
    expect(driver).to have_received(:quit)
  end

  it "requires CAPYBARA_APP_HOST when CHROME_URL is configured" do
    capture = described_class.new(output_dir: output_dir, changed_files: [])
    ENV["CHROME_URL"] = "ws://localhost:9222"
    ENV.delete("CAPYBARA_APP_HOST")

    expect { capture.send(:setup_capybara) }.to raise_error(
      RuntimeError,
      /CAPYBARA_APP_HOST must be set/
    )
  end
end
