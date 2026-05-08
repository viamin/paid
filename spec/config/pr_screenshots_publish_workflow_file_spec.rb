# frozen_string_literal: true

require "rails_helper"
require "psych"

class PrScreenshotsPublishWorkflowFile < Pathname
end

RSpec.describe PrScreenshotsPublishWorkflowFile do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/pr-screenshots-publish.yml"),
      aliases: true
    )
  end

  let(:job) { workflow.fetch("jobs").fetch("publish") }
  let(:resolve_step) { job.fetch("steps").find { |step| step["name"] == "Resolve PR capture run" } }

  it "queries screenshot capture runs by the PR head sha" do
    expect(resolve_step.fetch("run")).to include('head_sha=#{head_sha}&per_page=100')
  end
end
