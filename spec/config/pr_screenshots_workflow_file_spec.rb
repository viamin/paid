# frozen_string_literal: true

require "rails_helper"
require "psych"

class PrScreenshotsWorkflowFile < Pathname
end

RSpec.describe PrScreenshotsWorkflowFile, :no_db do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/pr-screenshots.yml"),
      aliases: true
    )
  end

  let(:capture_job) { workflow.fetch("jobs").fetch("capture") }
  let(:services) { capture_job.fetch("services") }
  let(:env) { capture_job.fetch("env") }
  let(:steps) { capture_job.fetch("steps") }
  let(:chrome_service) { services.fetch("chrome") }
  let(:verify_step) { steps.find { |step| step["name"] == "Verify Chrome service" } }
  let(:capybara_step) { steps.find { |step| step["name"] == "Configure remote Capybara host" } }

  it "provides a remote Chrome service for screenshot drivers" do
    expect(chrome_service).to include(
      "image" => "ghcr.io/browserless/chromium:v2.48.2"
    )
    expect(env).to include("CHROME_URL" => "ws://localhost:9222")
  end

  it "does not depend on a container-internal chrome health check" do
    expect(chrome_service).not_to have_key("options")
  end

  it "verifies the remote Chrome service before capture" do
    expect(verify_step).to be_present
    expect(verify_step.fetch("run")).to include("for attempt in $(seq 1 30); do")
    expect(verify_step.fetch("run")).to include("http://localhost:9222/json/version")
  end

  it "exports CAPYBARA_APP_HOST when a remote browser is configured" do
    expect(capybara_step).to be_present
    expect(capybara_step.fetch("run")).to include('echo "CAPYBARA_APP_HOST=$host_ip" >> "$GITHUB_ENV"')
  end
end
