# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::GithubProxyController, :no_db, type: :controller do
  let(:project_stub_class) do
    Class.new(Struct.new(:full_name, :enabled_review_bot_logins)) do
      def review_method_enabled?(_method)
        true
      end
    end
  end

  describe "#dismiss_stale_changes_requested_reviews" do
    subject(:dismiss_stale_reviews) do
      controller.send(:dismiss_stale_changes_requested_reviews, path_match, new_review)
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

  describe "#find_recent_paid_review" do
    let(:match) { { owner: "testowner", repo: "testrepo", number: "10" } }
    let(:token) { "ghs_token" }
    let(:marker) { Api::GithubProxyController::REVIEW_COMMENT_MARKER }
    let(:header) { Api::GithubProxyController::REVIEW_HEADER }
    let(:forwarded_body) { { body: "#{marker}\n#{header}\n\nLooks good" }.to_json }
    let(:raw_body) { { body: "Looks good" }.to_json }
    let(:project) do
      instance_double(
        project_stub_class,
        full_name: "testowner/testrepo",
        review_method_enabled?: true,
        enabled_review_bot_logins: Set["paid-code-reviewer[bot]"]
      )
    end

    before do
      allow(controller).to receive_messages(request: double(raw_post: raw_body),
        authenticated_project: project)
    end

    def stub_list(reviews)
      allow(controller).to receive(:github_api_call).with(
        :get,
        "repos/testowner/testrepo/pulls/10/reviews?per_page=100",
        token,
        nil
      ).and_return(
        instance_double(Faraday::Response, status: 200, body: reviews.to_json)
      )
    end

    it "returns the most recent review whose body includes the Paid marker" do
      stub_list([
        { id: 1, state: "COMMENTED", body: "old", submitted_at: 1.day.ago.iso8601 },
        { id: 2, state: "COMMENTED", body: "#{marker}\n#{header}\n\nLooks good", submitted_at: Time.current.iso8601 }
      ])

      result = controller.send(:find_recent_paid_review, match, token, forwarded_body, raw_body)

      expect(result["id"]).to eq(2)
    end

    it "skips pending reviews even if their body matches" do
      stub_list([
        { id: 9, state: "PENDING", body: "#{marker}\n#{header}\n\nLooks good", submitted_at: Time.current.iso8601 }
      ])

      result = controller.send(:find_recent_paid_review, match, token, forwarded_body, raw_body)

      expect(result).to be_nil
    end

    it "returns nil when the listing call fails" do
      allow(controller).to receive(:github_api_call).and_raise(Faraday::TimeoutError.new("expired"))
      allow(Rails.logger).to receive(:error)

      result = controller.send(:find_recent_paid_review, match, token, forwarded_body, raw_body)

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:error).with(
        hash_including(message: "github_proxy.review_recovery_list_failed")
      )
    end

    it "matches by raw body when the marker is missing but the body matches within the time window" do
      stub_list([
        { id: 11, state: "COMMENTED", body: "Looks good", submitted_at: 1.minute.ago.iso8601 }
      ])

      result = controller.send(:find_recent_paid_review, match, token, forwarded_body, raw_body)

      expect(result["id"]).to eq(11)
    end

    it "ignores body matches whose submitted_at lies outside the recovery window" do
      stub_list([
        { id: 22, state: "COMMENTED", body: "Looks good", submitted_at: 5.hours.ago.iso8601 }
      ])

      agent_run = instance_double(
        AgentRun,
        started_at: 2.hours.ago,
        created_at: 2.hours.ago
      )
      controller.instance_variable_set(:@agent_run, agent_run)

      result = controller.send(:find_recent_paid_review, match, token, forwarded_body, raw_body)

      expect(result).to be_nil
    end
  end

  describe "Api::SyntheticResponse" do
    it "exposes status and body" do
      response = Api::SyntheticResponse.new(status: 200, body: "ok")

      expect(response.status).to eq(200)
      expect(response.body).to eq("ok")
      expect(response.success?).to be(true)
    end

    it "reports success? as false for non-2xx statuses" do
      response = Api::SyntheticResponse.new(status: 422, body: "{}")

      expect(response.success?).to be(false)
    end

    it "looks up headers by both string and symbol keys" do
      response = Api::SyntheticResponse.new(
        status: 200,
        body: "{}",
        headers: { "Content-Type" => "application/json" }
      )

      expect(response["Content-Type"]).to eq("application/json")
      expect(response[:content_type]).to be_nil
    end
  end
end
