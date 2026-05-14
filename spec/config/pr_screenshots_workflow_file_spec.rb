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
  let(:publish_workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/pr-screenshots-publish.yml"),
      aliases: true
    )
  end
  let(:publish_job) { publish_workflow.fetch("jobs").fetch("publish") }
  let(:services) { capture_job.fetch("services") }
  let(:env) { capture_job.fetch("env") }
  let(:steps) { capture_job.fetch("steps") }
  let(:install_browser_step) { steps.find { |step| step["name"] == "Install Chromium-family browser" } }
  let(:browser_step) { steps.find { |step| step["name"] == "Locate Chromium-family browser" } }
  let(:role_step) { steps.find { |step| step["name"] == "Create application database role" } }
  let(:resolve_publish_step) { publish_job.fetch("steps").find { |step| step["name"] == "Resolve PR capture run" } }

  it "provisions a Chromium-family browser before capture" do
    expect(install_browser_step).to be_present
    expect(install_browser_step.fetch("run")).to include("google-chrome-stable")
    expect(install_browser_step.fetch("run")).to include("https://dl.google.com/linux/chrome/deb/")
  end

  it "uses the runner's local Chromium-family browser for capture" do
    expect(env).not_to have_key("CHROME_URL")
    expect(browser_step).to be_present
    expect(browser_step.fetch("run")).to include('path="$(command -v google-chrome || command -v chromium-browser || command -v chromium || true)"')
    expect(browser_step.fetch("run")).to include('echo "CHROMIUM_PATH=$path" >> "$GITHUB_ENV"')
    expect(browser_step.fetch("run")).to include('Chromium-family browser is required for screenshot capture.')
  end

  it "does not define a remote Chrome service for screenshot capture" do
    expect(services).not_to have_key("chrome")
  end

  it "does not install a separate PostgreSQL client for screenshot capture" do
    expect(steps.find { |step| step["name"] == "Install PostgreSQL client" }).to be_nil
  end

  it "uploads screenshot artifacts only when capture produced PNGs" do
    upload_step = steps.find { |step| step["name"] == "Upload screenshots to artifacts" }

    expect(upload_step).to be_present
    expect(upload_step.fetch("if")).to include("hashFiles('tmp/screenshots/*.png') != ''")
    expect(upload_step.fetch("with")).to include("if-no-files-found" => "error")
  end

  it "uses the default postgres service credentials instead of a custom application role" do
    expect(env).to include(
      "DB_USERNAME" => "postgres",
      "DB_PASSWORD" => "postgres"
    )
    expect(role_step).to be_nil
  end

  it "falls back to a capture_failed publish status when capture run resolution fails" do
    expect(resolve_publish_step).to be_present
    expect(resolve_publish_step.fetch("run")).to include('comment_status = "capture_failed"')
    expect(resolve_publish_step.fetch("run")).to include('rescue StandardError => e')
    expect(resolve_publish_step.fetch("run")).to include('Timed out waiting for PR Screenshots capture workflow')
  end
end
