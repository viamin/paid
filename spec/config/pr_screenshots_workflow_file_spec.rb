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

  def detect_steps
    workflow.fetch("jobs").fetch("detect").fetch("steps")
  end

  def detect_step(name)
    detect_steps.find { |step| step["name"] == name }
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

  it "pins the detect job to the repo Ruby version before running the UI detector" do
    expect(detect_step("Set up Ruby")).to include(
      "uses" => "ruby/setup-ruby@95ef2b042f9d7a56d8268cba8559e2842e2ad01b"
    )
    expect(detect_step("Set up Ruby").fetch("with")).to include(
      "ruby-version" => ".tool-versions"
    )
  end

  it "uses a dedicated non-superuser application role for screenshot capture" do
    expect(workflow.fetch("jobs").fetch("capture").fetch("env")).to include(
      "DATABASE_URL" => "postgres://paid:paid@localhost:5432/paid_test",
      "DB_USERNAME" => "paid",
      "DB_PASSWORD" => "paid"
    )

    expect(capture_step("Create application database role").fetch("run")).to include(
      "ALTER ROLE paid CREATEDB NOSUPERUSER NOBYPASSRLS;"
    )
  end

  it "pulls Postgres from the ECR Public mirror to avoid Docker Hub init failures" do
    expect(workflow.fetch("jobs").fetch("capture").fetch("services").fetch("postgres")).to include(
      "image" => "public.ecr.aws/docker/library/postgres:16.14"
    )
  end

  it "uses a known-good Chrome install and exports CHROMIUM_PATH for capture" do
    setup_step = capture_step("Set up Chrome")
    export_step = capture_step("Export Chromium path")
    capture_screenshots_step = capture_step("Capture screenshots")

    expect(setup_step).to include(
      "id" => "setup_chrome",
      "uses" => "browser-actions/setup-chrome@2e1d749697dd1612b833dba4a722266286fbefcd"
    )
    expect(export_step).to include("id" => "export_chromium_path")
    expect(export_step.fetch("env")).to include(
      "INSTALLED_CHROME_PATH" => "${{ steps.setup_chrome.outputs.chrome-path }}"
    )
    expect(export_step.fetch("run")).to include('echo "chromium_path=$chrome_path" >> "$GITHUB_OUTPUT"')
    expect(capture_screenshots_step.fetch("env")).to include(
      "CHROMIUM_PATH" => "${{ steps.export_chromium_path.outputs.chromium_path }}"
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
