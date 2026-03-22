# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecoverMissingPrLabelsJob do
  describe "#perform" do
    let(:project) { create(:project, owner: "viamin", repo: "paid") }
    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(GithubClient).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:add_labels_to_issue)
    end

    it "reapplies the paid-generated label to a Paid-created PR missing it locally" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      pull_request = create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [])

      described_class.perform_now

      expect(github_client).to have_received(:add_labels_to_issue)
        .with("viamin/paid", 416, [ "paid-generated" ])
      expect(pull_request.reload.labels).to include("paid-generated")
    end

    it "skips PRs that already have the label locally" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [ "paid-generated" ])

      described_class.perform_now

      expect(github_client).not_to have_received(:add_labels_to_issue)
    end

    it "continues when GitHub relabeling fails" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      pull_request = create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [])
      allow(github_client).to receive(:add_labels_to_issue)
        .and_raise(GithubClient::ApiError.new("boom", status: 422))

      expect { described_class.perform_now }.not_to raise_error
      expect(pull_request.reload.labels).to eq([])
    end

    it "deduplicates multiple completed runs for the same PR" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR A",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR B",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [])

      described_class.perform_now

      expect(github_client).to have_received(:add_labels_to_issue).once
    end
  end
end
