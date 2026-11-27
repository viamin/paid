# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe PullRequests::RecordOperatorAcceptanceReport do # @spec FOCUSED-RUN-015
  let(:account) { create(:account) }
  let(:actor) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, owner: "acme", repo: "alpha", allowed_github_usernames: [ "acme" ]) }
  let(:pull_request) { create(:issue, :pull_request, project:, github_number: 5389) }
  let(:comment) do
    OpenStruct.new(id: 7157569292, html_url: "https://github.com/acme/alpha/pull/5389#issuecomment-7157569292",
      body: "Acceptance report", user: OpenStruct.new(login: "acme"))
  end
  let(:client) { instance_double(GithubClient) }

  before do
    allow(client).to receive(:issue_comments).with(project.full_name, 5389).and_return([ comment ])
    allow(client).to receive(:pull_request).with(project.full_name, 5389)
      .and_return(OpenStruct.new(head: OpenStruct.new(sha: "b" * 40)))
  end

  it "binds one inspectable receipt without creating a run and is idempotent" do
    first = described_class.call(pull_request:, actor:, comment_id: comment.id,
      environment: "devcontainer", results: "63/0 source acceptance", unrun_capabilities: [ "CI" ], client:)
    second = described_class.call(pull_request:, actor:, comment_id: comment.id,
      environment: "devcontainer", results: "63/0 source acceptance", unrun_capabilities: [ "CI" ], client:)

    expect(first).to be_created
    expect(second).not_to be_created
    expect(first.event.metadata).to include("project_id" => project.id, "pull_request_number" => 5389,
      "comment_id" => comment.id.to_s, "revision" => "b" * 40, "environment" => "devcontainer")
    expect(AgentRun.where(project:)).to be_empty
  end

  it "rejects an untrusted comment without recording evidence" do
    comment.user.login = "stranger"

    expect {
      described_class.call(pull_request:, actor:, comment_id: comment.id, environment: "devcontainer", results: "pass", client:)
    }.to raise_error(ArgumentError, /not trusted/)
    expect(account.account_activity_events).to be_empty
  end
end
