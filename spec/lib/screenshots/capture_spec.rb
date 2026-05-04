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

  describe "#register_driver" do
    it "rewrites ws_url host from /json/version response" do
      ENV["CHROME_URL"] = "http://localhost:3000"
      capture = described_class.new(output_dir: output_dir, changed_files: [])

      version_json = { "webSocketDebuggerUrl" => "ws://container-abc:3000/devtools/browser/uuid-1" }.to_json
      allow(Net::HTTP).to receive(:get).and_return(version_json)

      registered_options = nil
      allow(Capybara).to receive(:register_driver).with(:paid_screenshots) do |&block|
        mock_app = instance_double(Capybara::Session)
        allow(Capybara::Cuprite::Driver).to receive(:new) do |_app, **opts|
          registered_options = opts
          driver
        end
        block.call(mock_app)
      end

      capture.send(:register_driver)

      expect(registered_options[:ws_url]).to eq("ws://localhost:3000/devtools/browser/uuid-1")
      expect(registered_options).not_to have_key(:browser_path)
    end

    it "rewrites ws_url host for https CHROME_URL" do
      ENV["CHROME_URL"] = "https://chrome.example.com"
      capture = described_class.new(output_dir: output_dir, changed_files: [])

      version_json = { "webSocketDebuggerUrl" => "ws://internal:3000/devtools/browser/uuid-2" }.to_json
      allow(Net::HTTP).to receive(:get).and_return(version_json)

      registered_options = nil
      allow(Capybara).to receive(:register_driver).with(:paid_screenshots) do |&block|
        mock_app = instance_double(Capybara::Session)
        allow(Capybara::Cuprite::Driver).to receive(:new) do |_app, **opts|
          registered_options = opts
          driver
        end
        block.call(mock_app)
      end

      capture.send(:register_driver)

      expect(registered_options[:ws_url]).to eq("ws://chrome.example.com:443/devtools/browser/uuid-2")
      expect(registered_options).not_to have_key(:browser_path)
    end

    it "falls back to scheme-swapped URL when /json/version is unavailable" do
      ENV["CHROME_URL"] = "http://localhost:3000/"
      capture = described_class.new(output_dir: output_dir, changed_files: [])

      allow(Net::HTTP).to receive(:get).and_raise(Errno::ECONNREFUSED)

      registered_options = nil
      allow(Capybara).to receive(:register_driver).with(:paid_screenshots) do |&block|
        mock_app = instance_double(Capybara::Session)
        allow(Capybara::Cuprite::Driver).to receive(:new) do |_app, **opts|
          registered_options = opts
          driver
        end
        block.call(mock_app)
      end

      capture.send(:register_driver)

      expect(registered_options[:ws_url]).to eq("ws://localhost:3000")
    end

    it "uses browser_path when CHROME_URL is not set" do
      ENV.delete("CHROME_URL")
      capture = described_class.new(output_dir: output_dir, changed_files: [])
      allow(capture).to receive(:find_chrome_binary).and_return("/usr/bin/chromium")

      registered_options = nil
      allow(Capybara).to receive(:register_driver).with(:paid_screenshots) do |&block|
        mock_app = instance_double(Capybara::Session)
        allow(Capybara::Cuprite::Driver).to receive(:new) do |_app, **opts|
          registered_options = opts
          driver
        end
        block.call(mock_app)
      end

      capture.send(:register_driver)

      expect(registered_options).not_to have_key(:ws_url)
      expect(registered_options[:browser_path]).to eq("/usr/bin/chromium")
    end
  end
end
