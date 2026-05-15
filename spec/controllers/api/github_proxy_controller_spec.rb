# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::GithubProxyController, :no_db, type: :controller do
  describe "#dismiss_stale_changes_requested_reviews" do
    subject(:dismiss_stale_reviews) do
      controller.send(:dismiss_stale_changes_requested_reviews, path_match, new_review)
    end

    let(:project_stub_class) do
      Class.new(Struct.new(:full_name, :enabled_review_bot_logins)) do
        def review_method_enabled?(_method)
          true
        end
      end
    end

    let(:path_match) { { number: "10" } }
    let(:new_review) { { "id" => 999, "state" => "COMMENTED" } }
    let(:project) do
      instance_double(
        project_stub_class,
        full_name: "testowner/testrepo",
        review_method_enabled?: true,
        enabled_review_bot_logins: Set["paid-code-reviewer[bot]"]
      )
    end
    let(:token_provider) { instance_double(Github::ReviewBotInstallationToken, fetch: "ghs_review_bot_token") }
    let(:client) { instance_double(GithubClient) }

    before do
      allow(controller).to receive(:authenticated_project).and_return(project)
      allow(Github::ReviewBotInstallationToken).to receive_messages(configured?: true, new: token_provider)
      allow(ProviderSupport).to receive(:provider_bot_usernames_for).with("paid_agent")
        .and_return(Set["paid-code-reviewer[bot]"])
      allow(GithubClient).to receive(:new).with(token: "ghs_review_bot_token").and_return(client)
      allow(client).to receive(:dismiss_pull_request_review)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)
    end

    it "dismisses only older paid-code-reviewer change requests" do
      allow(client).to receive(:pull_request_reviews).with("testowner/testrepo", 10).and_return([
        { id: 101, user_login: "paid-code-reviewer[bot]", state: "CHANGES_REQUESTED" },
        { id: 999, user_login: "paid-code-reviewer[bot]", state: "COMMENTED" },
        { id: 1001, user_login: "paid-code-reviewer[bot]", state: "CHANGES_REQUESTED" },
        { id: 102, user_login: "copilot-pull-request-reviewer[bot]", state: "CHANGES_REQUESTED" }
      ])

      dismiss_stale_reviews

      expect(client).to have_received(:dismiss_pull_request_review).with(
        "testowner/testrepo", 10, 101,
        message: Api::GithubProxyController::STALE_REVIEW_DISMISSAL_MESSAGE
      ).once
      expect(client).not_to have_received(:dismiss_pull_request_review).with(
        "testowner/testrepo", 10, 1001, any_args
      )
      expect(client).not_to have_received(:dismiss_pull_request_review).with(
        "testowner/testrepo", 10, 102, any_args
      )
    end

    it "matches bot logins from raw GitHub user payloads" do
      allow(client).to receive(:pull_request_reviews).with("testowner/testrepo", 10).and_return([
        { id: 101, user: { login: "paid-code-reviewer[bot]" }, state: "CHANGES_REQUESTED" },
        { id: 999, user: { login: "paid-code-reviewer[bot]" }, state: "COMMENTED" }
      ])

      dismiss_stale_reviews

      expect(client).to have_received(:dismiss_pull_request_review).with(
        "testowner/testrepo", 10, 101,
        message: Api::GithubProxyController::STALE_REVIEW_DISMISSAL_MESSAGE
      ).once
    end

    it "prefers submitted_at over review id when deciding staleness" do
      timed_review = {
        "id" => 500,
        "state" => "COMMENTED",
        "submitted_at" => "2026-05-15T12:00:00Z"
      }
      allow(client).to receive(:pull_request_reviews).with("testowner/testrepo", 10).and_return([
        { id: 1001, user_login: "paid-code-reviewer[bot]", state: "CHANGES_REQUESTED", submitted_at: "2026-05-15T11:00:00Z" },
        { id: 101, user_login: "paid-code-reviewer[bot]", state: "CHANGES_REQUESTED", submitted_at: "2026-05-15T13:00:00Z" }
      ])

      controller.send(:dismiss_stale_changes_requested_reviews, path_match, timed_review)

      expect(client).to have_received(:dismiss_pull_request_review).with(
        "testowner/testrepo", 10, 1001,
        message: Api::GithubProxyController::STALE_REVIEW_DISMISSAL_MESSAGE
      ).once
      expect(client).not_to have_received(:dismiss_pull_request_review).with(
        "testowner/testrepo", 10, 101, any_args
      )
    end

    it "skips dismissal when the new review requests changes" do
      allow(client).to receive(:pull_request_reviews)

      controller.send(:dismiss_stale_changes_requested_reviews, path_match, { "id" => 999, "state" => "CHANGES_REQUESTED" })

      expect(client).not_to have_received(:pull_request_reviews)
      expect(client).not_to have_received(:dismiss_pull_request_review)
    end

    it "skips dismissal when no paid-agent bot logins are enabled" do
      allow(project).to receive(:enabled_review_bot_logins).and_return(Set.new)
      allow(client).to receive(:pull_request_reviews)

      dismiss_stale_reviews

      expect(client).not_to have_received(:pull_request_reviews)
      expect(client).not_to have_received(:dismiss_pull_request_review)
    end

    it "skips malformed stale reviews without an id" do
      allow(client).to receive(:pull_request_reviews).with("testowner/testrepo", 10).and_return([
        { user_login: "paid-code-reviewer[bot]", state: "CHANGES_REQUESTED" },
        { id: 999, user_login: "paid-code-reviewer[bot]", state: "COMMENTED" }
      ])

      dismiss_stale_reviews

      expect(client).not_to have_received(:dismiss_pull_request_review)
    end
  end
end
