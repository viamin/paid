# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::CreateAggregatedPullRequestActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:client) { instance_double(GithubClient) }
  let(:github_token) { instance_double(GithubToken, client: client) }
  let(:pr_response) { OpenStruct.new(html_url: "https://github.com/test/repo/pull/42", number: 42) }

  before do
    allow(Project).to receive(:find).with(project.id).and_return(project)
    allow(project).to receive(:github_token).and_return(github_token)
    allow(client).to receive(:create_pull_request).and_return(pr_response)
    allow(client).to receive(:add_labels_to_issue)
  end

  describe "#execute" do
    let(:base_input) do
      {
        project_id: project.id,
        feature_branch: "feature/aggregated-test",
        merged_branches: [ "branch-1", "branch-2" ],
        failed_merges: [],
        results: [
          { success: true, issue_id: nil },
          { success: true, issue_id: nil }
        ]
      }
    end

    it "creates a draft PR on the project default branch" do
      result = activity.execute(base_input)

      expect(client).to have_received(:create_pull_request).with(
        project.full_name,
        hash_including(
          base: project.default_branch,
          head: "feature/aggregated-test",
          draft: true
        )
      )
      expect(result[:pull_request_url]).to eq("https://github.com/test/repo/pull/42")
      expect(result[:pull_request_number]).to eq(42)
    end

    it "includes parent issue in PR title when provided" do
      parent_issue = create(:issue, project: project, github_number: 99, title: "Big Feature")

      activity.execute(base_input.merge(parent_issue_id: parent_issue.id))

      expect(client).to have_received(:create_pull_request).with(
        anything,
        hash_including(title: "Feature #99: Big Feature")
      )
    end

    it "uses generic title when no parent issue" do
      activity.execute(base_input)

      expect(client).to have_received(:create_pull_request).with(
        anything,
        hash_including(title: "Aggregated feature changes")
      )
    end

    it "includes sub-task references in PR body" do
      issue = create(:issue, project: project, github_number: 10, title: "Sub-task A")
      input = base_input.merge(
        results: [ { success: true, issue_id: issue.id } ]
      )

      activity.execute(input)

      expect(client).to have_received(:create_pull_request) do |_, opts|
        expect(opts[:body]).to include("##{issue.github_number}")
        expect(opts[:body]).to include("Sub-task A")
      end
    end

    it "uses internal id fallback without GitHub-style # prefix" do
      input = base_input.merge(
        results: [ { success: true, issue_id: 999 } ]
      )

      activity.execute(input)

      expect(client).to have_received(:create_pull_request) do |_, opts|
        expect(opts[:body]).to include("internal issue id 999")
        expect(opts[:body]).not_to include("#999")
      end
    end

    it "includes fallback bullet for sub-tasks with no issue linked" do
      input = base_input.merge(
        results: [ { success: true, issue_id: nil }, { success: false, issue_id: nil } ]
      )

      activity.execute(input)

      expect(client).to have_received(:create_pull_request) do |_, opts|
        expect(opts[:body]).to include("Sub-task (no issue linked) (completed)")
        expect(opts[:body]).to include("Sub-task (no issue linked) (failed)")
      end
    end

    it "includes merge failure details in PR body" do
      input = base_input.merge(
        failed_merges: [ { branch: "branch-3", error: "Merge conflict" } ]
      )

      activity.execute(input)

      expect(client).to have_received(:create_pull_request) do |_, opts|
        expect(opts[:body]).to include("Merge Conflicts")
        expect(opts[:body]).to include("`branch-3`")
      end
    end

    it "adds labels when auto_add_labels_enabled" do
      activity.execute(base_input)

      expect(client).to have_received(:add_labels_to_issue).with(
        project.full_name,
        42,
        [ project.generated_label_name, project.automation_label_name ]
      )
    end

    it "skips labels when auto_add_labels disabled" do
      allow(project).to receive(:auto_add_labels_enabled?).and_return(false)

      activity.execute(base_input)

      expect(client).not_to have_received(:add_labels_to_issue)
    end

    it "handles label addition failure gracefully" do
      allow(client).to receive(:add_labels_to_issue).and_raise(GithubClient::Error, "Not Found")

      result = activity.execute(base_input)

      expect(result[:pull_request_url]).to eq("https://github.com/test/repo/pull/42")
    end

    it "returns existing PR on 422 retry" do
      existing_pr = OpenStruct.new(html_url: "https://github.com/test/repo/pull/42", number: 42)

      allow(client).to receive(:create_pull_request)
        .and_raise(GithubClient::ApiError.new("Validation Failed", status: 422))
      allow(client).to receive(:pull_requests).and_return([ existing_pr ])

      result = activity.execute(base_input)

      expect(result[:pull_request_url]).to eq("https://github.com/test/repo/pull/42")
      expect(result[:pull_request_number]).to eq(42)
    end

    it "re-raises 422 when no existing PR is found" do
      allow(client).to receive(:create_pull_request)
        .and_raise(GithubClient::ApiError.new("Validation Failed", status: 422))
      allow(client).to receive(:pull_requests).and_return([])

      expect {
        activity.execute(base_input)
      }.to raise_error(GithubClient::ApiError, "Validation Failed")
    end
  end
end
