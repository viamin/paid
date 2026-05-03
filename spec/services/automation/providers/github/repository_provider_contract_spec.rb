# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Automation::Providers::Github::RepositoryProvider do
  context "with contract verification" do
  let(:client) { instance_double(GithubClient) }
  let(:project_class) do
    Class.new do
      attr_accessor :github_token
      def full_name = "acme/widgets"
    end
  end
  let(:project) { project_class.new }
  let(:adapter) { described_class.new(project, client: client) }
  let(:repo) { "acme/widgets" }
  let(:pr_number) { 42 }
  let(:ref) { "abc123" }
  let(:label_name) { "automation" }
  let(:comment_body) { "test comment" }

  def provider_failure_message = "missing pull request"

  def stub_expected_provider_failure
    allow(client).to receive(:pull_request)
      .with(repo, 999)
      .and_raise(GithubClient::NotFoundError.new(provider_failure_message))
  end

  def invoke_expected_provider_failure
    proc { adapter.fetch_pull_request(repo: repo, number: 999) }
  end

  def stub_missing_label_provider_failure
    allow(client).to receive(:remove_label_from_issue)
      .with(repo, pr_number, label_name)
      .and_raise(GithubClient::NotFoundError, "Label does not exist")
  end

  before do
    pr_resource = OpenStruct.new(
      number: 42, title: "Test", body: "desc", state: "open",
      draft: false, merged: false, mergeable: true, merged_at: nil,
      created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 1, 2),
      html_url: "https://github.com/acme/widgets/pull/42",
      head: OpenStruct.new(ref: "feature", sha: "abc123"),
      base: OpenStruct.new(ref: "main"),
      user: OpenStruct.new(login: "Alice"),
      labels: [ OpenStruct.new(name: "automation") ]
    )

    allow(client).to receive_messages(
      pull_request: pr_resource,
      pull_requests: [ pr_resource ],
      pull_request_files: [ "a.rb" ],
      check_runs_for_ref: [
        { name: "test", status: "completed", conclusion: "success",
          html_url: "https://github.com/acme/widgets/runs/1", details_url: nil }
      ],
      add_labels_to_issue: nil,
      remove_label_from_issue: nil,
      mark_pull_request_ready: nil
    )
    allow(client).to receive_messages(add_comment: OpenStruct.new(
        id: 99, body: comment_body, created_at: Time.utc(2026, 1, 1),
        updated_at: nil, html_url: nil,
        user: OpenStruct.new(login: "bot")
      ), merge_pull_request: OpenStruct.new(merged: true, sha: "def456", message: "Merged"))
  end

    it_behaves_like "a RepositoryProvider implementation"
  end
end
