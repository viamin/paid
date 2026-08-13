# frozen_string_literal: true

require "rails_helper"
require "screenshots/driver/playwright"

RSpec.describe Screenshots::Driver::Playwright do
  let(:config) do
    Screenshots::Configuration.from_hash(
      "driver" => "playwright",
      "base_url" => "http://example.test",
      "routes" => [ { "path" => "/", "name" => "home" } ]
    )
  end
  let(:driver) { described_class.new(config:) }

  around do |example|
    original_chrome_url = ENV["CHROME_URL"]
    example.run
  ensure
    ENV["CHROME_URL"] = original_chrome_url
  end

  it "requires CHROME_URL when starting the browser" do
    ENV.delete("CHROME_URL")

    expect { driver.start_browser }.to raise_error(RuntimeError, /CHROME_URL must be set/)
  end

  it "normalizes relative URLs against the configured base URL" do
    allow(driver).to receive(:rpc_call)

    driver.visit("/dashboard")

    expect(driver).to have_received(:rpc_call).with("visit", url: "http://example.test/dashboard")
  end

  it "uses the current page pathname from the helper response" do
    allow(driver).to receive(:rpc_call).with("current_path").and_return({ "current_path" => "/dashboard" })

    expect(driver.current_path).to eq("/dashboard")
  end

  it "uses a fresh browser context and page for each helper session" do
    helper_source = File.read(driver.send(:helper_path))

    expect(helper_source).to include("context = await browser.newContext({ viewport });")
    expect(helper_source).to include("page = await context.newPage();")
    expect(helper_source).not_to include("browser.contexts()[0]")
    expect(helper_source).not_to include("context.pages()[0]")
  end
end
