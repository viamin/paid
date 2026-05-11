# frozen_string_literal: true

require "rails_helper"
require "psych"

class PrScreenshotsPublishWorkflowFile < Pathname
end

RSpec.describe PrScreenshotsPublishWorkflowFile, :no_db do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/pr-screenshots-publish.yml"),
      aliases: true
    )
  end

  let(:job) { workflow.fetch("jobs").fetch("publish") }
  let(:permissions) { job.fetch("permissions") }
  let(:resolve_step) { job.fetch("steps").find { |step| step["name"] == "Resolve PR capture run" } }
  let(:resolve_env) { resolve_step.fetch("env") }

  it "queries screenshot capture runs by the PR head sha" do
    expect(resolve_step.fetch("run")).to include('head_sha=#{head_sha}&per_page=100')
  end

  it "passes the PR head ref to the resolver for branch-based fallback matching" do
    expect(resolve_env).to include("HEAD_REF" => "${{ github.event.pull_request.head.ref }}")
    expect(resolve_step.fetch("run")).to include('candidate["head_branch"] == head_ref')
  end

  it "grants contents write permission for branch-based screenshot publishing" do
    expect(permissions).to include("contents" => "write")
  end
end
