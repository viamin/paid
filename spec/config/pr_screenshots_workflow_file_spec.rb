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

  it "scopes concurrency by PR number and action to avoid cross-event self-cancellation" do
    expect(workflow.fetch("concurrency")).to include(
      "group" => "pr-screenshots-${{ github.workflow }}-${{ github.event.pull_request.number }}-${{ github.event.action }}",
      "cancel-in-progress" => true
    )
  end

  it "does not fail artifact upload when screenshot capture produced no PNGs" do
    upload_step = workflow.fetch("jobs").fetch("capture").fetch("steps").find do |step|
      step["name"] == "Upload screenshots to artifacts"
    end

    expect(upload_step.dig("with", "if-no-files-found")).to eq("ignore")
  end

  it "loads screenshot detection from the app services load path instead of require_relative in ruby -e" do
    detect_step = workflow.fetch("jobs").fetch("detect").fetch("steps").find do |step|
      step["name"] == "Detect UI-facing changes"
    end

    expect(detect_step.fetch("run")).to include('ruby -Iapp/services -e')
    expect(detect_step.fetch("run")).to include('require "screenshots/detect_ui_changes"')
  end

  it "pins the detect job to the repository Ruby version before executing the inline script" do
    setup_step = workflow.fetch("jobs").fetch("detect").fetch("steps").find do |step|
      step["name"] == "Set up Ruby"
    end

    expect(setup_step).to include(
      "uses" => "ruby/setup-ruby@6aaa311d81eba98ae12eaffbcb63296ace0efcde"
    )
    expect(setup_step.fetch("with")).to include(
      "ruby-version" => ".tool-versions"
    )
  end

  it "passes test credentials to capture and tolerates runners without a preinstalled browser" do
    capture_job = workflow.fetch("jobs").fetch("capture")
    locate_step = capture_job.fetch("steps").find do |step|
      step["name"] == "Locate Chromium-family browser"
    end

    expect(capture_job.fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_MASTER_KEY" => "${{ secrets.RAILS_MASTER_KEY }}",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}"
    )
    expect(locate_step.fetch("run")).to include('command -v chromium || true')
  end
end
