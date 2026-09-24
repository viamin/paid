# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::EnforceMutationTrust do
  let(:project) { create(:project, allowed_github_usernames: [ "trusted-user" ]) }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(project).to receive(:client).and_return(client)
    allow(client).to receive(:update_issue)
    allow(client).to receive(:add_comment)
  end

  # @spec GITHUB-SYNC-013
  it "allows an allowlisted user to edit an issue" do
    result = described_class.call(
      project: project,
      action: "edited",
      issue_number: 42,
      actor_login: "TRUSTED-USER"
    )

    expect(result).to eq(:allowed)
    expect(client).not_to have_received(:update_issue)
    expect(client).not_to have_received(:add_comment)
    expect(AccountActivityEvent.last).to have_attributes(action: "issue.mutation_trust_verified", subject: project)
    expect(AccountActivityEvent.last.metadata).to include(
      "actor_login" => "TRUSTED-USER",
      "trusted" => true,
      "decision" => "allow"
    )
  end

  # @spec GITHUB-SYNC-013
  it "closes and explains an untrusted reopen" do
    result = described_class.call(
      project: project,
      action: "reopened",
      issue_number: 42,
      actor_login: "untrusted-user"
    )

    expect(result).to eq(:closed)
    expect(client).to have_received(:update_issue).with(project.full_name, 42, state: "closed")
    expect(client).to have_received(:add_comment).with(project.full_name, 42, described_class::UNTRUSTED_MUTATION_COMMENT)
    expect(AccountActivityEvent.last.metadata).to include(
      "actor_login" => "untrusted-user",
      "trusted" => false,
      "action" => "reopened",
      "decision" => "close"
    )
  end

  # @spec GITHUB-SYNC-013
  it "treats a missing sender identity as untrusted" do
    described_class.call(project: project, action: "edited", issue_number: 42, actor_login: nil)

    expect(client).to have_received(:update_issue).with(project.full_name, 42, state: "closed")
  end
end
