# frozen_string_literal: true

require "rails_helper"

# @spec TDD-GUARD-007
# @spec TDD-GUARD-008
RSpec.describe Tdd::ReturnToTestReview do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user, owner: "acme", repo: "alpha") }
  let(:github_client) { instance_double(GithubClient) }
  let(:agent_run) { create(:agent_run, :existing_pr, project: project, tdd_phase: "test_fixing") }

  let!(:pull_request) do
    create(:issue, :pull_request,
      project: project,
      github_number: 42,
      labels: [ "paid-generated", "paid-tests-approved" ])
  end

  before do
    allow(project).to receive(:client).and_return(github_client)
    allow(github_client).to receive(:remove_label_from_issue)
    allow(github_client).to receive(:add_labels_to_issue)
  end

  describe ".call" do
    it "swaps the labels on GitHub and locally, and records the reset" do
      result = described_class.call(agent_run: agent_run)

      expect(result).to be_success
      expect(github_client).to have_received(:remove_label_from_issue)
        .with(project.full_name, 42, "paid-tests-approved")
      expect(github_client).to have_received(:add_labels_to_issue)
        .with(project.full_name, 42, [ "paid-tests-ready-for-review" ])

      pull_request.reload
      expect(pull_request.labels).to include("paid-tests-ready-for-review")
      expect(pull_request.labels).not_to include("paid-tests-approved")

      expect(agent_run.reload.tdd_returned_to_test_review).to be(true)
    end

    it "applies the local label update under a row lock" do
      expect_any_instance_of(Issue).to receive(:with_lock).and_call_original # rubocop:disable RSpec/AnyInstance

      described_class.call(agent_run: agent_run)
    end

    context "when the run is not in test_fixing phase" do
      before { agent_run.update!(tdd_phase: "refactor") }

      it "fails without raising and does not touch labels or the flag" do
        result = described_class.call(agent_run: agent_run)

        expect(result).not_to be_success
        expect(result.error).to eq(:not_test_fixing_phase)
        expect(github_client).not_to have_received(:remove_label_from_issue)
        expect(agent_run.reload.tdd_returned_to_test_review).to be(false)
      end
    end

    context "when no pull request number is resolvable" do
      before { agent_run.update!(source_pull_request_number: nil, pull_request_number: nil) }

      it "fails without raising" do
        result = described_class.call(agent_run: agent_run)

        expect(result).not_to be_success
        expect(result.error).to eq(:no_pull_request)
        expect(agent_run.reload.tdd_returned_to_test_review).to be(false)
      end
    end

    context "when the project has no GitHub client" do
      before { allow(project).to receive(:client).and_return(nil) }

      it "fails without raising" do
        result = described_class.call(agent_run: agent_run)

        expect(result).not_to be_success
        expect(result.error).to eq(:no_github_client)
        expect(agent_run.reload.tdd_returned_to_test_review).to be(false)
      end
    end

    context "when the remote label sync fails" do
      before do
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::ApiError.new("500 Internal Server Error"))
        allow(Rails.logger).to receive(:warn)
      end

      it "still records the reset locally and logs a warning" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(agent_run.reload.tdd_returned_to_test_review).to be(true)
        expect(Rails.logger).to have_received(:warn)
          .with(hash_including(message: "tdd.return_to_test_review_label_sync_failed"))
      end
    end
  end
end
