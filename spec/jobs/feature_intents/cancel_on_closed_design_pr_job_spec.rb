# frozen_string_literal: true

require "rails_helper"

RSpec.describe FeatureIntents::CancelOnClosedDesignPrJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:feature_intent) { create(:feature_intent, :ready_for_approval, project: project) }
  let(:implementation_issue) { create(:issue, project: project, github_state: "open") }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow_any_instance_of(Project).to receive(:upstream_pr_target?).and_return(false) # rubocop:disable RSpec/AnyInstance
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:update_issue)
  end

  context "with a non-terminal feature intent" do
    let!(:design_pr) do
      create(:feature_intent_design_pr, feature_intent: feature_intent, pull_request_number: 42,
        head_sha: "a" * 40, reviewed_head_sha: "a" * 40)
    end

    before do
      create(:feature_intent_issue, feature_intent: feature_intent, issue: implementation_issue)
    end

    # @spec FEATURE-APPROVAL-017
    it "cancels the feature and closes the linked issue on GitHub and locally" do
      described_class.perform_now(project.id, pr_number: design_pr.pull_request_number)

      expect(feature_intent.reload.status).to eq("cancelled")
      expect(implementation_issue.reload.github_state).to eq("closed")
      expect(github_client).to have_received(:update_issue)
        .with(project.full_name, implementation_issue.github_number, state: "closed")
    end

    # @spec FEATURE-APPROVAL-017
    it "is a no-op when no design PR matches the pull_request_number" do
      described_class.perform_now(project.id, pr_number: 1000)

      expect(feature_intent.reload.status).to eq("design_open")
      expect(implementation_issue.reload.github_state).to eq("open")
    end

    # @spec FEATURE-APPROVAL-017
    it "discards when the project no longer exists" do
      described_class.perform_now(project.id + 999, pr_number: design_pr.pull_request_number)

      expect(feature_intent.reload.status).to eq("design_open")
    end
  end

  context "with a terminal-status feature intent" do
    %w[released revising cancelled].each do |status|
      it "leaves a #{status} feature unchanged" do
        feature_intent = create(:feature_intent, :ready_for_approval, project: project, status: status)
        create(:feature_intent_design_pr, feature_intent: feature_intent, pull_request_number: 42,
          head_sha: "a" * 40, reviewed_head_sha: "a" * 40)
        create(:feature_intent_issue, feature_intent: feature_intent, issue: implementation_issue)

        described_class.perform_now(project.id, pr_number: 42)

        expect(feature_intent.reload.status).to eq(status)
        expect(implementation_issue.reload.github_state).to eq("open")
      end
    end
  end
end
