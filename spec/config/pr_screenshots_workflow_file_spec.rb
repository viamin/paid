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

  it "does not fail the workflow when no screenshot files were generated" do
    upload_step = workflow.fetch("jobs").fetch("capture").fetch("steps").find do |step|
      step["name"] == "Upload screenshots to artifacts"
    end

    expect(upload_step.dig("with", "if-no-files-found")).to eq("ignore")
  end
end
