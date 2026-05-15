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
  let(:resolve_step) { job.fetch("steps").find { |step| step["name"] == "Resolve PR capture run" } }
  let(:resolve_env) { resolve_step.fetch("env") }

  it "scopes concurrency by PR number and action to avoid cross-event self-cancellation" do
    expect(workflow.fetch("concurrency")).to include(
      "group" => "pr-screenshots-publish-${{ github.event.pull_request.number }}-${{ github.event.action }}",
      "cancel-in-progress" => true
    )
  end

  it "queries screenshot capture runs by the PR head sha" do
    expect(resolve_step.fetch("run")).to include('head_sha=#{head_sha}&per_page=100')
  end

  it "passes the PR head ref to the resolver for branch-based fallback matching" do
    expect(resolve_env).to include("HEAD_REF" => "${{ github.event.pull_request.head.ref }}")
    expect(resolve_step.fetch("run")).to include('if pull_requests.any?')
    expect(resolve_step.fetch("run")).to include('candidate["head_branch"] == head_ref')
  end

  it "uses branch fallback matching only when the workflow run is not already attached to a PR" do
    expect(resolve_step.fetch("run")).to include('pull_requests = candidate.fetch("pull_requests", [])')
    expect(resolve_step.fetch("run")).to include('pull_requests.any? { |pr| pr["number"] == pr_number }')
  end

  it "treats missing capture jobs as skipped only when detect completed cleanly" do
    expect(resolve_step.fetch("run")).to include('elsif detect_job && %w[success neutral skipped].include?(detect_job["conclusion"])')
    expect(resolve_step.fetch("run")).to include('"Could not find a successful capture job, and detect did not complete cleanly')
  end
end
