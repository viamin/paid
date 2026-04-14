# frozen_string_literal: true

require "rails_helper"
require "psych"

class ClaudeCodeReviewWorkflowFile < Pathname
end

RSpec.describe ClaudeCodeReviewWorkflowFile do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/claude-code-review.yml"),
      aliases: true
    )
  end

  let(:job) { workflow.fetch("jobs").fetch("claude-review") }
  let(:permissions) { job.fetch("permissions") }
  let(:steps) { job.fetch("steps") }

  it "emits the configured Claude Code Review check-run name" do
    expect(job.fetch("name")).to eq("Claude Code Review")
  end

  it "can write check runs for the PR head sha gate" do
    expect(permissions.fetch("checks")).to eq("write")
  end

  it "creates and completes a Claude Code Review check run on the PR head sha" do
    expect(steps).to include(
      a_hash_including(
        "name" => "Start PR head check run",
        "env" => a_hash_including("HEAD_SHA" => "${{ steps.pr.outputs.head_sha }}")
      ),
      a_hash_including(
        "name" => "Complete PR head check run",
        "if" => "always()",
        "env" => a_hash_including("CHECK_RUN_ID" => "${{ steps.check-run.outputs.id }}")
      )
    )
  end

  it "completes successfully for fork-backed PRs without running Claude" do
    expect(steps).to include(
      a_hash_including(
        "name" => "Skip fork-backed PRs without blocking the CI gate",
        "if" => "steps.pr.outputs.head_repo_fork == 'true'",
        "run" => "echo \"Skipping Claude review for fork-backed PR.\""
      )
    )
  end
end
