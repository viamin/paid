# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::GithubProxy" do
  let(:project) { create(:project, owner: "testowner", repo: "testrepo") }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:github_token) { project.github_token }
  let(:chat_session) { create(:chat_session, account: project.account, project: nil) }

  let(:valid_headers) do
    {
      "Content-Type" => "application/json",
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.proxy_token
    }
  end

  let(:issue_response_body) do
    {
      id: 1,
      number: 42,
      title: "Test issue",
      html_url: "https://github.com/testowner/testrepo/issues/42",
      state: "open"
    }.to_json
  end

  let(:issues_list_body) do
    [ { id: 1, number: 1, title: "Existing issue" } ].to_json
  end

  describe "POST /api/proxy/github/repos/:owner/:repo/issues" do
    let(:target_url) { "https://api.github.com/repos/testowner/testrepo/issues" }

    before do
      stub_request(:post, target_url)
        .to_return(status: 201, body: issue_response_body, headers: { "Content-Type" => "application/json" })
    end

    context "with valid agent run" do
      it "proxies the request to GitHub and returns the response" do
        post "/api/proxy/github/repos/testowner/testrepo/issues",
          params: { title: "New issue", body: "Description" }.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:created)
        body = JSON.parse(response.body)
        expect(body["number"]).to eq(42)
      end

      it "injects authorization header" do
        post "/api/proxy/github/repos/testowner/testrepo/issues",
          params: { title: "New issue" }.to_json,
          headers: valid_headers

        expect(WebMock).to have_requested(:post, target_url)
          .with(headers: {
            "Authorization" => "Bearer #{github_token.token}",
            "Accept" => "application/vnd.github+json"
          })
      end

      it "tracks created issue on the agent run" do
        post "/api/proxy/github/repos/testowner/testrepo/issues",
          params: { title: "New issue" }.to_json,
          headers: valid_headers

        agent_run.reload
        expect(agent_run.created_issue_url).to eq("https://github.com/testowner/testrepo/issues/42")
        expect(agent_run.created_issue_number).to eq(42)
      end

      it "touches last_used_at on the github token" do
        expect {
          post "/api/proxy/github/repos/testowner/testrepo/issues",
            params: { title: "New issue" }.to_json,
            headers: valid_headers
        }.to change { github_token.reload.last_used_at }
      end
    end
  end

  describe "GET /api/proxy/github/repos/:owner/:repo/issues" do
    let(:target_url) { "https://api.github.com/repos/testowner/testrepo/issues" }

    before do
      stub_request(:get, target_url)
        .to_return(status: 200, body: issues_list_body, headers: { "Content-Type" => "application/json" })
    end

    it "proxies GET requests" do
      get "/api/proxy/github/repos/testowner/testrepo/issues",
        headers: valid_headers

      expect(response).to have_http_status(:ok)
    end

    it "does not track issue creation for GET requests" do
      get "/api/proxy/github/repos/testowner/testrepo/issues",
        headers: valid_headers

      expect(agent_run.reload.created_issue_url).to be_nil
    end

    it "returns forbidden for a projectless chat session" do
      get "/api/proxy/github/repos/testowner/testrepo/issues",
        headers: {
          "Content-Type" => "application/json",
          "X-Chat-Session-Id" => chat_session.id.to_s,
          "X-Proxy-Token" => chat_session.proxy_token
        }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => "Project required")
    end
  end

  describe "PATCH /api/proxy/github/repos/:owner/:repo/issues/:number" do
    let(:target_url) { "https://api.github.com/repos/testowner/testrepo/issues/42" }

    before do
      stub_request(:patch, target_url)
        .to_return(status: 200, body: issue_response_body, headers: { "Content-Type" => "application/json" })
    end

    it "proxies PATCH requests" do
      patch "/api/proxy/github/repos/testowner/testrepo/issues/42",
        params: { state: "closed" }.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/proxy/github/repos/:owner/:repo/issues/:number/comments" do
    let(:target_url) { "https://api.github.com/repos/testowner/testrepo/issues/42/comments" }

    before do
      stub_request(:post, target_url)
        .to_return(status: 201, body: { id: 1, body: "Comment" }.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "proxies comment creation" do
      post "/api/proxy/github/repos/testowner/testrepo/issues/42/comments",
        params: { body: "A comment" }.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:created)
    end
  end

  describe "GET /api/proxy/github/repos/:owner/:repo/issues/:number/comments" do
    let(:target_url) { "https://api.github.com/repos/testowner/testrepo/issues/42/comments" }

    before do
      stub_request(:get, target_url)
        .to_return(status: 200, body: [ { id: 1, body: "Prior discussion" } ].to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "proxies comment listing" do
      get "/api/proxy/github/repos/testowner/testrepo/issues/42/comments",
        headers: valid_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).first["body"]).to eq("Prior discussion")
    end
  end

  describe "POST /api/proxy/github/repos/:owner/:repo/issues/:number/labels" do
    let(:target_url) { "https://api.github.com/repos/testowner/testrepo/issues/42/labels" }

    before do
      stub_request(:post, target_url)
        .to_return(status: 200, body: [ { name: "bug" } ].to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "proxies label addition" do
      post "/api/proxy/github/repos/testowner/testrepo/issues/42/labels",
        params: { labels: [ "bug" ] }.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/proxy/github/repos/:owner/:repo/pulls/:number/reviews" do
    let(:agent_run) { create(:agent_run, :running, :review_goal, project: project) }
    let(:target_url) { "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews" }
    let(:review_bot_token_provider) { instance_double(Github::ReviewBotInstallationToken, fetch: "ghs_review_bot_token") }
    let(:review_response_body) do
      {
        id: 999,
        body: "Review summary",
        html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-999",
        state: "commented"
      }.to_json
    end

    before do
      stub_request(:post, target_url)
        .to_return(status: 200, body: review_response_body, headers: { "Content-Type" => "application/json" })
      allow(Rails.logger).to receive(:warn).and_call_original
    end

    def stub_review_list_response(reviews = [])
      stub_request(:get, target_url)
        .with(
          headers: { "Authorization" => "token ghs_review_bot_token" },
          query: hash_including("per_page" => "100")
        )
        .to_return(
          status: 200,
          body: reviews.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    # Stub the GET to list reviews without an auth header check, so the
    # Faraday-based recovery flow (which sends "Bearer …") matches in tests
    # that don't go through Octokit.
    def stub_reviews_listing(reviews = [])
      stub_request(:get, target_url)
        .with(query: hash_including("per_page" => "100"))
        .to_return(
          status: 200,
          body: reviews.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    def stub_stale_review_dismissal(review_id: 101)
      dismiss_url = "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/#{review_id}/dismissals"

      stub_request(:put, dismiss_url)
        .with(
          headers: { "Authorization" => "token ghs_review_bot_token" },
          body: { message: "Subsequent review found no remaining actionable issues." }.to_json
        )
        .to_return(status: 200, body: {}.to_json, headers: { "Content-Type" => "application/json" })

      dismiss_url
    end

    def clean_review_response_body
      {
        id: 999,
        body: "Generated no new comments. The PR looks ready as-is. <!-- paid-review-clean -->",
        html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-999",
        state: "commented",
        comments: []
      }.to_json
    end

    it "proxies review creation" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:ok)
    end

    it "prepends the Code Review header to the review body" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      sent_body = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.body)
      expect(sent_body["body"]).to start_with("<!-- paid:code-review -->\n## Code Review\n\n")
      expect(sent_body["body"]).to end_with("Looks good")
    end

    it "does not duplicate the header when already present" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "<!-- paid:code-review -->\n## Code Review\n\nAlready has header", event: "COMMENT" }.to_json,
        headers: valid_headers

      sent_body = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.body)
      expect(sent_body["body"]).to eq("<!-- paid:code-review -->\n## Code Review\n\nAlready has header")
    end

    it "does not prepend the header for non-review-goal runs" do
      non_review_run = create(:agent_run, :running, project: project,
        goal: "create_pr", source_pull_request_number: 10)

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "X-Agent-Run-Id" => non_review_run.id.to_s,
          "X-Proxy-Token" => non_review_run.proxy_token
        }

      sent_body = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.body)
      expect(sent_body["body"]).to eq("Looks good")
    end

    it "tracks review_posted_at when PR number matches source_pull_request_number" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_posted_at).to be_present
      expect(agent_run.review_url).to eq("https://github.com/testowner/testrepo/pull/10#pullrequestreview-999")
    end

    it "records a succeeded review proxy diagnostic (#2779)" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_proxy_diagnostics["outcome"]).to eq("succeeded")
    end

    it "does not track review_posted_at when PR number does not match" do
      mismatched_url = "https://api.github.com/repos/testowner/testrepo/pulls/99/reviews"
      stub_request(:post, mismatched_url)
        .to_return(status: 200, body: review_response_body, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/pulls/99/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_posted_at).to be_nil
    end

    it "does not track review_posted_at for non-review goal runs" do
      non_review_run = create(:agent_run, :running, project: project,
        goal: "create_pr", source_pull_request_number: 10)

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "X-Agent-Run-Id" => non_review_run.id.to_s,
          "X-Proxy-Token" => non_review_run.proxy_token
        }

      non_review_run.reload
      expect(non_review_run.review_posted_at).to be_nil
    end

    it "does not overwrite review_posted_at when already set" do
      original_time = 1.hour.ago
      agent_run.update!(review_posted_at: original_time, review_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-original")

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Second review", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_posted_at).to be_within(1.second).of(original_time)
      expect(agent_run.review_url).to eq("https://github.com/testowner/testrepo/pull/10#pullrequestreview-original")
    end

    it "tracks review with a derived URL when html_url is missing from response" do
      no_url_response = { id: 999, body: "Review summary", state: "commented" }.to_json
      stub_request(:post, target_url)
        .to_return(status: 200, body: no_url_response, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_posted_at).to be_present
      expect(agent_run.review_url).to eq("https://github.com/testowner/testrepo/pull/10#pullrequestreview-999")
    end

    it "backfills review_url when review_posted_at is set but review_url is missing" do
      original_time = 1.hour.ago
      agent_run.update!(review_posted_at: original_time, review_url: nil)

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Follow-up review", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_posted_at).to be_within(1.second).of(original_time)
      expect(agent_run.review_url).to eq("https://github.com/testowner/testrepo/pull/10#pullrequestreview-999")
    end

    it "does not track review_posted_at on upstream error" do
      stub_request(:post, target_url)
        .to_return(status: 422, body: { message: "Validation Failed" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_posted_at).to be_nil
    end

    it "records an upstream_error review proxy diagnostic with the HTTP status (#2779)" do
      stub_request(:post, target_url)
        .to_return(status: 422, body: { message: "Validation Failed" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_proxy_diagnostics).to include(
        "outcome" => "upstream_error",
        "http_status" => 422
      )
    end

    it "logs a warning when review has zero inline comments and actionable body" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Several issues found", event: "COMMENT" }.to_json,
        headers: valid_headers

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "github_proxy.review_missing_inline_comments",
          agent_run_id: agent_run.id,
          review_id: 999,
          comment_count: 0
        )
      )
    end

    it "does not log a warning when review includes inline comments" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: {
          body: "Some issues",
          event: "COMMENT",
          comments: [ { path: "file.rb", position: 1, body: "Fix this" } ]
        }.to_json,
        headers: valid_headers

      expect(Rails.logger).not_to have_received(:warn).with(
        hash_including(message: "github_proxy.review_missing_inline_comments")
      )
    end

    it "logs a warning when body-only review lacks the paid clean marker" do
      no_marker_response = {
        id: 999,
        body: "Generated no new comments",
        html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-999",
        state: "commented"
      }.to_json
      stub_request(:post, target_url)
        .to_return(status: 200, body: no_marker_response, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Generated no new comments", event: "COMMENT" }.to_json,
        headers: valid_headers

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "github_proxy.review_missing_inline_comments")
      )
    end

    it "does not log a warning for approved body-only reviews" do
      approved_response = {
        id: 999,
        body: "Looks good to me",
        html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-999",
        state: "APPROVED"
      }.to_json
      stub_request(:post, target_url)
        .to_return(status: 200, body: approved_response, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good to me", event: "APPROVE" }.to_json,
        headers: valid_headers

      expect(Rails.logger).not_to have_received(:warn).with(
        hash_including(message: "github_proxy.review_missing_inline_comments")
      )
    end

    it "does not log a warning when review body includes the clean marker" do
      clean_review_response = {
        id: 999,
        body: "Generated no new comments. <!-- paid-review-clean -->",
        html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-999",
        state: "commented"
      }.to_json
      stub_request(:post, target_url)
        .to_return(status: 200, body: clean_review_response, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: {
          body: "Generated no new comments. <!-- paid-review-clean -->",
          event: "COMMENT",
          comments: []
        }.to_json,
        headers: valid_headers

      expect(Rails.logger).not_to have_received(:warn).with(
        hash_including(message: "github_proxy.review_missing_inline_comments")
      )
    end

    context "when paid_agent review is enabled" do
      before do
        allow(Github::ReviewBotInstallationToken).to receive_messages(
          configured?: true,
          new: review_bot_token_provider
        )
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => { "paid_agent" => { "enabled" => true } }
        })
        stub_review_list_response
      end

      it "forwards review creation with the review bot token" do
        post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
          params: { body: "Looks good", event: "COMMENT" }.to_json,
          headers: valid_headers

        expect(WebMock).to have_requested(:post, target_url)
          .with(headers: {
            "Authorization" => "Bearer ghs_review_bot_token",
            "Accept" => "application/vnd.github+json"
          })
      end

      it "does not touch last_used_at on the project GitHub token" do
        freeze_time do
          github_token.update_column(:last_used_at, 2.days.ago)

          expect {
            post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
              params: { body: "Looks good", event: "COMMENT" }.to_json,
              headers: valid_headers
          }.not_to change { github_token.reload.last_used_at }
        end
      end

      context "when older paid-code-reviewer change requests exist" do
        it "dismisses the stale bot change request" do
          stub_review_list_response([
            { id: 101, user: { login: "paid-code-reviewer[bot]" }, state: "CHANGES_REQUESTED", body: "Needs work" },
            { id: 102, user: { login: "paid-code-reviewer[bot]" }, state: "COMMENTED", body: "Looks good" },
            { id: 999, user: { login: "paid-code-reviewer[bot]" }, state: "COMMENTED", body: "Latest review" },
            { id: 103, user: { login: "human-reviewer" }, state: "CHANGES_REQUESTED", body: "Human request" }
          ])
          dismiss_url = stub_stale_review_dismissal
          allow(Rails.logger).to receive(:info)

          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers

          expect(WebMock).to have_requested(:put, dismiss_url).once
          expect(Rails.logger).to have_received(:info).with(
            hash_including(message: "github_proxy.dismissed_stale_review", review_id: 101, pr_number: 10)
          )
        end

        it "dismisses stale bot change requests even when the review was already tracked on the run" do
          agent_run.update!(
            review_posted_at: 1.hour.ago,
            review_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-previous"
          )
          stub_review_list_response([
            { id: 101, user: { login: "paid-code-reviewer[bot]" }, state: "CHANGES_REQUESTED", body: "Needs work" },
            { id: 999, user: { login: "paid-code-reviewer[bot]" }, state: "COMMENTED", body: "Latest review" }
          ])
          dismiss_url = stub_stale_review_dismissal

          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers

          expect(WebMock).to have_requested(:put, dismiss_url).once
          expect(agent_run.reload.review_url)
            .to eq("https://github.com/testowner/testrepo/pull/10#pullrequestreview-previous")
        end

        it "does not dismiss newer bot change requests" do
          stub_review_list_response([
            { id: 1001, user: { login: "paid-code-reviewer[bot]" }, state: "CHANGES_REQUESTED", body: "Needs work" },
            { id: 999, user: { login: "paid-code-reviewer[bot]" }, state: "COMMENTED", body: "Latest review" }
          ])
          dismiss_url = "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/1001/dismissals"

          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers

          expect(WebMock).not_to have_requested(:put, dismiss_url)
        end

        it "does not dismiss stale change requests from other enabled review bots" do
          project.update!(review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => { "enabled" => true },
              "copilot" => { "enabled" => true }
            }
          })
          stub_review_list_response([
            { id: 101, user: { login: "copilot-pull-request-reviewer[bot]" }, state: "CHANGES_REQUESTED", body: "Copilot request" },
            { id: 999, user: { login: "paid-code-reviewer[bot]" }, state: "COMMENTED", body: "Latest review" }
          ])
          dismiss_url = "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/101/dismissals"

          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers

          expect(WebMock).not_to have_requested(:put, dismiss_url)
        end

        it "does not dismiss stale change requests when paid_agent bot logins resolve empty" do
          allow(RunnerSupport).to receive(:runner_bot_usernames_for).with("paid_agent").and_return(Set.new)
          stub_review_list_response([
            { id: 101, user: { login: "paid-code-reviewer[bot]" }, state: "CHANGES_REQUESTED", body: "Needs work" },
            { id: 999, user: { login: "paid-code-reviewer[bot]" }, state: "COMMENTED", body: "Latest review" }
          ])
          dismiss_url = "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/101/dismissals"

          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers

          expect(WebMock).not_to have_requested(:put, dismiss_url)
        end
      end

      it "does not dismiss reviews when the latest review requests changes" do
        changes_requested_response = {
          id: 999,
          body: "Needs fixes",
          html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-999",
          state: "CHANGES_REQUESTED"
        }.to_json
        dismiss_url = "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/101/dismissals"

        stub_request(:post, target_url)
          .to_return(status: 200, body: changes_requested_response, headers: { "Content-Type" => "application/json" })

        post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
          params: { body: "Needs fixes", event: "REQUEST_CHANGES" }.to_json,
          headers: valid_headers

        expect(WebMock).not_to have_requested(:put, dismiss_url)
      end

      it "does not query or dismiss stale reviews when the review response lacks an id" do
        no_id_response = {
          body: "Looks good",
          html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-999",
          state: "commented"
        }.to_json
        review_list_url = "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews"

        stub_request(:post, target_url)
          .to_return(status: 200, body: no_id_response, headers: { "Content-Type" => "application/json" })

        post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
          params: { body: "Looks good", event: "COMMENT" }.to_json,
          headers: valid_headers

        expect(WebMock).not_to have_requested(:get, review_list_url)
      end

      it "returns 503 when the review bot is not configured" do
        allow(review_bot_token_provider)
          .to receive(:fetch)
          .and_raise(Github::ReviewBotInstallationToken::ConfigurationError, "Paid review bot GitHub App is not configured")

        post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
          params: { body: "Looks good", event: "COMMENT" }.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:service_unavailable)
        expect(JSON.parse(response.body)["error"]).to include("not configured")
        expect(agent_run.reload.review_proxy_diagnostics).not_to include("outcome" => "attempted")
      end

      context "when a stale PENDING review blocks the POST with 422 (#2324)" do
        before do
          conflict_body = {
            message: "Unprocessable Entity",
            errors: [ "User can only have one pending review per pull request" ],
            status: "422"
          }.to_json
          stub_request(:post, target_url)
            .to_return(
              { status: 422, body: conflict_body, headers: { "Content-Type" => "application/json" } },
              { status: 200, body: review_response_body, headers: { "Content-Type" => "application/json" } }
            )
          stub_request(:get, "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews?per_page=100")
            .to_return(
              status: 200,
              body: [
                { id: 4380830777, state: "PENDING", user: { login: "paid-code-reviewer[bot]" } },
                { id: 4376258909, state: "COMMENTED", user: { login: "paid-code-reviewer[bot]" } }
              ].to_json,
              headers: { "Content-Type" => "application/json" }
            )
          stub_request(:delete, "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/4380830777")
            .to_return(status: 200, body: { id: 4380830777 }.to_json, headers: { "Content-Type" => "application/json" })
          allow(Rails.logger).to receive(:info)
        end

        it "deletes the stale pending review and retries the POST once" do
          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers

          expect(WebMock).to have_requested(:delete, "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/4380830777").once
          expect(WebMock).to have_requested(:post, target_url).twice
          expect(response).to have_http_status(:ok)
          expect(Rails.logger).to have_received(:info).with(
            hash_including(message: "github_proxy.pending_review_recovered",
                           pending_review_id: 4380830777,
                           pr_number: 10)
          )
          agent_run.reload
          expect(agent_run.review_posted_at).to be_present
        end

        it "leaves the original 422 in place when no PENDING review is present" do
          stub_request(:get, "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews?per_page=100")
            .to_return(
              status: 200,
              body: [ { id: 1, state: "COMMENTED", user: { login: "paid-code-reviewer[bot]" } } ].to_json,
              headers: { "Content-Type" => "application/json" }
            )

          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers

          expect(WebMock).not_to have_requested(:delete, "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/4380830777")
          expect(WebMock).to have_requested(:post, target_url).once
          expect(response).to have_http_status(:unprocessable_content)
        end

        it "leaves the original 422 in place when the DELETE fails" do
          stub_request(:delete, "https://api.github.com/repos/testowner/testrepo/pulls/10/reviews/4380830777")
            .to_return(status: 500, body: {}.to_json, headers: { "Content-Type" => "application/json" })

          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers

          expect(WebMock).to have_requested(:post, target_url).once
          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      it "logs the upstream response body when GitHub rejects the review POST" do
        validation_body = { message: "Validation Failed",
                            errors: [ { resource: "PullRequestReviewComment", code: "missing_field", field: "path" } ] }.to_json
        stub_request(:post, target_url)
          .to_return(status: 422, body: validation_body, headers: { "Content-Type" => "application/json" })
        allow(Rails.logger).to receive(:warn)

        post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
          params: { body: "Looks good", event: "COMMENT" }.to_json,
          headers: valid_headers

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "github_proxy.upstream_error",
            status: 422,
            agent_run_id: agent_run.id
          )
        )
      end

      it "logs a warning when a non-clean review body is posted without inline comments" do
        allow(Rails.logger).to receive(:warn)

        post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
          params: { body: "Found two issues to fix before merge.", event: "COMMENT", comments: [] }.to_json,
          headers: valid_headers

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "github_proxy.review_missing_inline_comments",
            agent_run_id: agent_run.id,
            review_id: 999,
            comment_count: 0
          )
        )
      end

      it "does not log a warning when the submitted review includes inline comments" do
        allow(Rails.logger).to receive(:warn)

        post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
          params: {
            body: "Found two issues to fix before merge.",
            event: "COMMENT",
            comments: [
              { path: "app/models/user.rb", line: 12, body: "Guard this branch." }
            ]
          }.to_json,
          headers: valid_headers

        expect(Rails.logger).not_to have_received(:warn).with(
          hash_including(message: "github_proxy.review_missing_inline_comments")
        )
      end

      it "does not log a warning for the clean review body-only format" do
        allow(Rails.logger).to receive(:warn)
        stub_request(:post, target_url)
          .to_return(status: 200, body: clean_review_response_body, headers: { "Content-Type" => "application/json" })

        post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
          params: {
            body: "Generated no new comments. The PR looks ready as-is. <!-- paid-review-clean -->",
            event: "COMMENT",
            comments: []
          }.to_json,
          headers: valid_headers

        expect(Rails.logger).not_to have_received(:warn).with(
          hash_including(message: "github_proxy.review_missing_inline_comments")
        )
      end

      context "when the POST times out before GitHub responds (#2778)" do
        def paid_marker_review_body
          "<!-- paid:code-review -->\n## Code Review\n\nLooks good"
        end

        def existing_paid_review
          {
            id: 888, state: "COMMENTED", body: paid_marker_review_body,
            html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-888",
            submitted_at: Time.current.iso8601, user: { login: "paid-code-reviewer[bot]" }
          }
        end

        def post_review
          post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
            params: { body: "Looks good", event: "COMMENT" }.to_json,
            headers: valid_headers
        end

        def silence_review_logs(error: false)
          allow(Rails.logger).to receive(:warn)
          allow(Rails.logger).to receive(:info)
          allow(Rails.logger).to receive(:error) if error
        end

        def stub_post_first_timeout
          post_call_count = 0
          stub_request(:post, target_url).to_return do |_req|
            post_call_count += 1
            raise Faraday::TimeoutError, "execution expired" if post_call_count == 1

            { status: 200, body: review_response_body, headers: { "Content-Type" => "application/json" } }
          end
        end

        def stub_post_raise(error)
          stub_request(:post, target_url).to_raise(error)
        end

        def unrelated_review
          { id: 1, state: "COMMENTED", body: "Unrelated older review", submitted_at: 1.day.ago.iso8601 }
        end

        it "recovers by listing PR reviews when the matching review already exists" do
          stub_post_raise(Faraday::TimeoutError.new("execution expired"))
          stub_reviews_listing([ existing_paid_review ])
          silence_review_logs

          post_review

          expect(response).to have_http_status(:ok)
          expect(WebMock).to have_requested(:post, target_url).once
          expect(Rails.logger).to have_received(:warn).with(
            hash_including(message: "github_proxy.upstream_timeout", agent_run_id: agent_run.id)
          )
          expect(Rails.logger).to have_received(:info).with(
            hash_including(message: "github_proxy.recovered_existing_review", review_id: 888)
          )
          agent_run.reload
          expect(agent_run.review_url)
            .to eq("https://github.com/testowner/testrepo/pull/10#pullrequestreview-888")
        end

        it "retries the POST when no matching review exists in the listing" do
          stub_post_first_timeout
          stub_reviews_listing([ unrelated_review ])
          silence_review_logs

          post_review

          expect(response).to have_http_status(:ok)
          expect(WebMock).to have_requested(:post, target_url).twice
          expect(Rails.logger).to have_received(:info).with(hash_including(message: "github_proxy.retry"))
          expect(Rails.logger).to have_received(:info).with(
            hash_including(message: "github_proxy.retry_succeeded", status: 200)
          )
        end

        it "logs final_failure when the retry also fails with a connection error" do
          stub_post_raise(Faraday::ConnectionFailed.new("connect refused"))
          stub_reviews_listing([ unrelated_review ])
          silence_review_logs(error: true)

          post_review

          expect(response).to have_http_status(:bad_gateway)
          expect(Rails.logger).to have_received(:error).with(
            hash_including(message: "github_proxy.final_failure")
          )
        end

        it "logs final_failure when the listing call itself times out" do
          stub_post_raise(Faraday::TimeoutError.new("execution expired"))
          stub_request(:get, target_url)
            .with(query: hash_including("per_page" => "100"))
            .to_raise(Faraday::TimeoutError.new("listing timed out"))
          silence_review_logs(error: true)

          post_review

          expect(response).to have_http_status(:bad_gateway)
          expect(Rails.logger).to have_received(:error).with(
            hash_including(message: "github_proxy.review_recovery_list_failed")
          )
        end

        it "ignores pending reviews when looking for the matching review" do
          pending_review = {
            id: 555, state: "PENDING", body: paid_marker_review_body,
            submitted_at: Time.current.iso8601, user: { login: "paid-code-reviewer[bot]" }
          }
          stub_post_first_timeout
          stub_reviews_listing([ pending_review ])
          silence_review_logs

          post_review

          expect(response).to have_http_status(:ok)
          expect(WebMock).to have_requested(:post, target_url).twice
        end

        it "does not double-post when a non-Pending review with the same body is found" do
          stub_post_raise(Faraday::TimeoutError.new("execution expired"))
          stub_reviews_listing([ existing_paid_review ])
          silence_review_logs

          post_review

          expect(WebMock).to have_requested(:post, target_url).once
        end

        it "matches by body+time-window even when the Paid marker is missing" do
          unmarker_review = {
            id: 777, state: "COMMENTED", body: "Looks good",
            html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-777",
            submitted_at: 1.minute.ago.iso8601, user: { login: "paid-code-reviewer[bot]" }
          }
          stub_post_raise(Faraday::TimeoutError.new("execution expired"))
          stub_reviews_listing([ unmarker_review ])
          silence_review_logs

          post_review

          expect(response).to have_http_status(:ok)
          expect(WebMock).to have_requested(:post, target_url).once
          agent_run.reload
          expect(agent_run.review_url)
            .to eq("https://github.com/testowner/testrepo/pull/10#pullrequestreview-777")
        end

        it "ignores older reviews whose body matches but lie outside the recovery window" do
          stale_match_review = {
            id: 444, state: "COMMENTED", body: "Looks good",
            html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-444",
            submitted_at: 3.hours.ago.iso8601, user: { login: "paid-code-reviewer[bot]" }
          }
          stub_post_first_timeout
          stub_reviews_listing([ stale_match_review ])
          silence_review_logs

          post_review

          expect(response).to have_http_status(:ok)
          expect(WebMock).to have_requested(:post, target_url).twice
        end
      end
    end
  end

  describe "repo mismatch" do
    it "returns 403 when the repo does not match the project" do
      stub_request(:get, "https://api.github.com/repos/otherowner/otherrepo/issues")
        .to_return(status: 200, body: "[]")

      get "/api/proxy/github/repos/otherowner/otherrepo/issues",
        headers: valid_headers

      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Repository mismatch")
    end
  end

  describe "case-insensitive repo matching" do
    it "allows case-insensitive repo matching" do
      stub_request(:get, "https://api.github.com/repos/TestOwner/TestRepo/issues")
        .to_return(status: 200, body: issues_list_body, headers: { "Content-Type" => "application/json" })

      get "/api/proxy/github/repos/TestOwner/TestRepo/issues",
        headers: valid_headers

      expect(response).to have_http_status(:ok)
    end
  end

  describe "disallowed endpoints" do
    it "returns 403 for POST to /pulls" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls",
        params: {}.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Endpoint not allowed")
    end

    it "rejects DELETE requests" do
      delete "/api/proxy/github/repos/testowner/testrepo/issues/42",
        headers: valid_headers

      expect(response).to have_http_status(:not_found)
        .or have_http_status(:forbidden)
    end

    it "returns 403 for non-issue endpoints" do
      get "/api/proxy/github/repos/testowner/testrepo/contents/README.md",
        headers: valid_headers

      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Endpoint not allowed")
    end
  end

  describe "authentication" do
    context "without X-Agent-Run-Id header" do
      it "returns unauthorized" do
        get "/api/proxy/github/repos/testowner/testrepo/issues",
          headers: { "Content-Type" => "application/json" }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with inactive agent run" do
      let(:completed_run) { create(:agent_run, :completed, project: project) }

      it "returns forbidden" do
        get "/api/proxy/github/repos/testowner/testrepo/issues",
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => completed_run.id.to_s,
            "X-Proxy-Token" => completed_run.proxy_token
          }

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "with invalid proxy token" do
      it "returns forbidden" do
        get "/api/proxy/github/repos/testowner/testrepo/issues",
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => agent_run.id.to_s,
            "X-Proxy-Token" => "invalid-token"
          }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "inactive GitHub token" do
    before do
      github_token.revoke!
    end

    it "returns 503 when GitHub token is revoked" do
      get "/api/proxy/github/repos/testowner/testrepo/issues",
        headers: valid_headers

      expect(response).to have_http_status(:service_unavailable)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("GitHub token not available")
    end
  end

  describe "upstream errors" do
    it "returns 502 when upstream connection fails" do
      stub_request(:get, "https://api.github.com/repos/testowner/testrepo/issues")
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      get "/api/proxy/github/repos/testowner/testrepo/issues",
        headers: valid_headers

      expect(response).to have_http_status(:bad_gateway)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Upstream request failed")
    end

    it "passes through upstream error status" do
      stub_request(:post, "https://api.github.com/repos/testowner/testrepo/issues")
        .to_return(status: 422, body: { message: "Validation Failed" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/issues",
        params: { title: "" }.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
