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

  def capture_steps
    workflow.fetch("jobs").fetch("capture").fetch("steps")
  end

  def capture_step(name)
    capture_steps.find { |step| step["name"] == name }
  end

  it "scopes concurrency by PR number and action to avoid cross-event self-cancellation" do
    expect(workflow.fetch("concurrency")).to include(
      "group" => "pr-screenshots-${{ github.workflow }}-${{ github.event.pull_request.number }}-${{ github.event.action }}",
      "cancel-in-progress" => true
    )
  end

  it "pins a stable test database name for the capture job" do
    expect(workflow.fetch("jobs").fetch("capture").fetch("env")).to include(
      "PAID_TEST_DATABASE" => "paid_test"
    )
  end

  it "locates Chromium via the runner PATH and exports CHROMIUM_PATH for capture" do
    locate_step = capture_step("Locate Chromium-family browser")
    export_step = capture_step("Export Chromium path")

    expect(locate_step.fetch("run")).to include("command -v chromium || true")
    expect(locate_step.fetch("id")).to eq("locate_chromium")
    expect(locate_step.fetch("run")).to include('echo "chrome_path=$chrome_path" >> "$GITHUB_OUTPUT"')
    expect(export_step.fetch("env")).to include(
      "LOCATED_CHROME_PATH" => "${{ steps.locate_chromium.outputs.chrome_path }}",
      "INSTALLED_CHROME_PATH" => "${{ steps.setup_chrome.outputs.chrome-path }}"
    )
    expect(export_step.fetch("run")).to include('echo "CHROMIUM_PATH=$chrome_path" >> "$GITHUB_ENV"')
  end

  it "installs a fallback Chrome binary when PATH discovery misses" do
    expect(capture_step("Set up Chrome fallback")).to include(
      "id" => "setup_chrome",
      "if" => "steps.locate_chromium.outputs.chrome_path == ''",
      "uses" => "browser-actions/setup-chrome@v2"
    )
  end

  it "uploads screenshot artifacts only when the capture job produced png files" do
    detect_step = capture_step("Detect captured screenshots")
    upload_step = capture_step("Upload screenshots to artifacts")

    expect(detect_step).to include(
      "id" => "detect_screenshots",
      "if" => "always()"
    )
    expect(detect_step.fetch("run")).to include('screenshots=(tmp/screenshots/*.png)')
    expect(detect_step.fetch("run")).to include('echo "has_screenshots=true" >> "$GITHUB_OUTPUT"')
    expect(detect_step.fetch("run")).to include('echo "has_screenshots=false" >> "$GITHUB_OUTPUT"')

    expect(upload_step).to include(
      "id" => "upload_screenshots",
      "if" => "always() && steps.detect_screenshots.outputs.has_screenshots == 'true'"
    )
    expect(upload_step.fetch("with")).to include(
      "path" => "tmp/screenshots/*.png",
      "if-no-files-found" => "ignore"
    )
  end

  it "normalizes a missing test key from RAILS_MASTER_KEY before capture boots Rails" do
    normalize_step = workflow.fetch("jobs").fetch("capture").fetch("steps").find do |step|
      step["name"] == "Normalize test master key"
    end

    expect(normalize_step).to include("if" => "env.RAILS_TEST_KEY == ''")
    expect(normalize_step.fetch("env")).to include("RAILS_MASTER_KEY_FALLBACK" => "${{ secrets.RAILS_MASTER_KEY }}")
    expect(normalize_step.fetch("run")).to include('echo "RAILS_TEST_KEY=$RAILS_MASTER_KEY_FALLBACK" >> "$GITHUB_ENV"')
  end
end
