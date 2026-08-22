# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::GithubProxyController, type: :controller do
  # @spec TDD-GUARD-007
  describe "#track_tdd_return_to_test_review" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user, owner: "acme", repo: "alpha") }
    let(:agent_run) { create(:agent_run, :existing_pr, project: project, tdd_phase: "test_fixing") }
    let!(:pull_request) do
      create(:issue, :pull_request,
        project: project,
        github_number: 42,
        labels: [ "paid-generated", "paid-tests-approved" ])
    end
    let(:response) do
      instance_double(Faraday::Response, body: {
        "labels" => [
          { "name" => "paid-generated" },
          { "name" => "paid-tests-ready-for-review" }
        ]
      }.to_json)
    end

    before do
      controller.instance_variable_set(:@agent_run, agent_run)
      allow(controller).to receive(:log_info)
      allow(controller).to receive(:log_error)
    end

    it "records the reset when the label proxy returns the source PR to test review" do
      controller.send(:track_tdd_return_to_test_review, "repos/acme/alpha/issues/42/labels", response)

      expect(agent_run.reload.tdd_returned_to_test_review).to be(true)
      expect(pull_request.reload.labels).to contain_exactly("paid-generated", "paid-tests-ready-for-review")
    end

    it "records the reset when an issue update returns the source PR to test review" do
      issue_response = instance_double(Faraday::Response, body: {
        "number" => 42,
        "pull_request" => { "html_url" => "https://github.com/acme/alpha/pull/42" },
        "labels" => [
          { "name" => "paid-generated" },
          { "name" => "paid-tests-ready-for-review" }
        ]
      }.to_json)

      controller.send(:track_tdd_return_to_test_review, "repos/acme/alpha/issues/42", issue_response)

      expect(agent_run.reload.tdd_returned_to_test_review).to be(true)
      expect(pull_request.reload.labels).to contain_exactly("paid-generated", "paid-tests-ready-for-review")
    end

    it "ignores label updates that do not return the PR to test review" do
      unchanged = instance_double(Faraday::Response, body: {
        "labels" => [
          { "name" => "paid-generated" },
          { "name" => "paid-tests-approved" }
        ]
      }.to_json)

      controller.send(:track_tdd_return_to_test_review, "repos/acme/alpha/issues/42/labels", unchanged)

      expect(agent_run.reload.tdd_returned_to_test_review).to be(false)
      expect(pull_request.reload.labels).to include("paid-tests-approved")
    end
  end
end
