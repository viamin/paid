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
  let(:steps) { job.fetch("steps") }

  it "emits the configured Claude Code Review check-run name" do
    expect(job.fetch("name")).to eq("Claude Code Review")
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
