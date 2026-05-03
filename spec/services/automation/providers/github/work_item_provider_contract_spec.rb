# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Automation::Providers::Github::WorkItemProvider do
  context "with contract verification" do
  let(:client) { instance_double(GithubClient) }
  let(:project_class) do
    Class.new do
      def full_name = "acme/widgets"
    end
  end
  let(:project) { project_class.new }
  let(:adapter) { described_class.new(project, client: client) }
  let(:repo) { "acme/widgets" }
  let(:issue_number) { 42 }
  let(:label_name) { "bug" }
  let(:comment_body) { "test comment" }
  let(:issue_resource) do
    OpenStruct.new(
      number: 42, title: "Bug", body: "details", state: "open",
      created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 1, 2),
      closed_at: nil, html_url: "https://github.com/acme/widgets/issues/42",
      user: OpenStruct.new(login: "Alice"),
      assignees: [ OpenStruct.new(login: "Bob") ],
      labels: [ OpenStruct.new(name: "bug") ],
      pull_request: nil
    )
  end

  def provider_failure_message = "missing issue"

  def stub_expected_provider_failure
    allow(client).to receive(:issue)
      .with(repo, 999)
      .and_raise(GithubClient::NotFoundError.new(provider_failure_message))
  end

  def invoke_expected_provider_failure
    proc { adapter.fetch_issue(repo: repo, number: 999) }
  end

  def stub_missing_label_provider_failure
    allow(client).to receive(:remove_label_from_issue)
      .with(repo, issue_number, label_name)
      .and_raise(GithubClient::NotFoundError, "Label does not exist")
  end

  before do
    allow(client).to receive_messages(
      issue: issue_resource,
      issues: [ issue_resource ],
      issue_comments: [
        OpenStruct.new(
          id: 1, body: "hi", created_at: Time.utc(2026, 1, 1),
          updated_at: nil, html_url: nil,
          user: OpenStruct.new(login: "alice")
        )
      ],
      issue_events: [
        { event: "labeled", created_at: Time.utc(2026, 1, 1),
          actor: { login: "alice" }, label: { name: "bug" } }
      ],
      create_issue: issue_resource,
      add_labels_to_issue: nil,
      remove_label_from_issue: nil,
      update_issue: issue_resource
    )
    allow(client).to receive(:add_comment).and_return(
      OpenStruct.new(
        id: 3, body: comment_body, created_at: Time.utc(2026, 1, 1),
        updated_at: nil, html_url: nil,
        user: OpenStruct.new(login: "bot")
      )
    )
  end

    it_behaves_like "a WorkItemProvider implementation"
  end
end
