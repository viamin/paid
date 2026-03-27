# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecoverMissingPullRequestLabelsJob do
  describe "#perform" do
    let(:project) { create(:project, owner: "viamin", repo: "paid") }
    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(GithubClient).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:add_labels_to_issue)
    end

    it "reapplies the generated and automation labels when both are missing" do
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
        .with("viamin/paid", 416, [ "paid-generated", "paid-automation" ])
      expect(pull_request.reload.labels).to include("paid-generated", "paid-automation")
    end

    context "when the generated label is already present" do
      it "skips recovery" do
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
    end

    context "when only the automation label is missing" do
      it "preserves manual opt-out" do
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
    end

    it "reapplies only the generated label when automation is still present" do
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
        labels: [ "paid-automation" ])

      described_class.perform_now

      expect(github_client).to have_received(:add_labels_to_issue)
        .with("viamin/paid", 416, [ "paid-generated" ])
      expect(pull_request.reload.labels).to include("paid-generated", "paid-automation")
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

    it "skips runs with no locally-synced PR record" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")

      described_class.perform_now

      expect(github_client).not_to have_received(:add_labels_to_issue)
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
