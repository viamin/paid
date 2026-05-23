# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventions::OpenHookGuardrailPullRequestJob do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:recommendation) do
    create(
      :project_convention_recommendation,
      project: project,
      action_type: "open_pr",
      evidence: {
        "strategy" => {
          "manager_type" => "husky",
          "hook_path" => ".husky/commit-msg",
          "validator_path" => ".paid/hooks/validate-commit-msg",
          "allowed_types" => %w[feat fix]
        }
      }
    )
  end
  let(:result) do
    ProjectConventions::OpenHookGuardrailPullRequest::Result.new(
      pull_request_url: "https://github.com/acme/widgets/pull/42",
      already_configured: false
    )
  end

  it "opens the pull request and marks the recommendation applied on success" do
    allow(ProjectConventions::OpenHookGuardrailPullRequest).to receive(:call).and_return(result)

    described_class.perform_now(project.id, recommendation.id, user.id)

    expect(ProjectConventions::OpenHookGuardrailPullRequest).to have_received(:call).with(
      project: project,
      recommendation: recommendation
    )
    expect(recommendation.reload).to be_applied
    expect(recommendation.applied_by).to eq(user)
    expect(recommendation.pull_request_url).to eq(result.pull_request_url)
  end

  it "leaves the recommendation pending on failure" do
    allow(ProjectConventions::OpenHookGuardrailPullRequest).to receive(:call)
      .and_raise(ProjectConventions::OpenHookGuardrailPullRequest::Error, "push failed")

    described_class.perform_now(project.id, recommendation.id, user.id)

    expect(recommendation.reload).to be_pending
  end
end
