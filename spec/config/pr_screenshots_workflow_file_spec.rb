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

  it "pins a stable test database name for the capture job" do
    expect(workflow.fetch("jobs").fetch("capture").fetch("env")).to include(
      "PAID_TEST_DATABASE" => "paid_test"
    )
  end

  it "locates Chromium via the runner PATH and exports CHROMIUM_PATH for capture" do
    locate_step = workflow.fetch("jobs").fetch("capture").fetch("steps").find do |step|
      step["name"] == "Locate Chromium-family browser"
    end

    expect(locate_step.fetch("run")).to include("command -v chromium || true")
    expect(locate_step.fetch("run")).to include('echo "CHROMIUM_PATH=$chrome_path" >> "$GITHUB_ENV"')
  end
end
