# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::GithubProxy" do
  let(:project) { create(:project, owner: "testowner", repo: "testrepo") }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:github_token) { project.github_token }

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
    let(:review_response_body) do
      {
        id: 999,
        body: "Review summary",
        html_url: "https://github.com/testowner/testrepo/pull/10#pullrequestreview-999",
        commit_id: "abc123def456",
        state: "commented"
      }.to_json
    end

    before do
      stub_request(:post, target_url)
        .to_return(status: 200, body: review_response_body, headers: { "Content-Type" => "application/json" })
    end

    it "proxies review creation" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:ok)
    end

    it "tracks review_posted_at when PR number matches source_pull_request_number" do
      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_posted_at).to be_present
      expect(agent_run.review_url).to eq("https://github.com/testowner/testrepo/pull/10#pullrequestreview-999")
      expect(agent_run.result_commit_sha).to eq("abc123def456")
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

    it "does not track review when html_url is missing from response" do
      no_url_response = { id: 999, body: "Review summary", state: "commented" }.to_json
      stub_request(:post, target_url)
        .to_return(status: 200, body: no_url_response, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/github/repos/testowner/testrepo/pulls/10/reviews",
        params: { body: "Looks good", event: "COMMENT" }.to_json,
        headers: valid_headers

      agent_run.reload
      expect(agent_run.review_posted_at).to be_nil
      expect(agent_run.review_url).to be_nil
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
