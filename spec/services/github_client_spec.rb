# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubClient do
  let(:token) { "ghp_test_token_123456789012345678901234567890" }
  let(:client) { described_class.new(token: token) }
  let(:api_base) { "https://api.github.com" }

  describe "#validate_token" do
    context "when token is valid" do
      before do
        stub_request(:get, "#{api_base}/user")
          .to_return(
            status: 200,
            body: {
              login: "testuser",
              id: 12345,
              name: "Test User",
              email: "test@example.com"
            }.to_json,
            headers: {
              "Content-Type" => "application/json",
              "X-OAuth-Scopes" => "repo, user"
            }
          )
      end

      it "returns user information" do
        result = client.validate_token

        expect(result[:login]).to eq("testuser")
        expect(result[:id]).to eq(12345)
        expect(result[:name]).to eq("Test User")
        expect(result[:email]).to eq("test@example.com")
      end
    end

    context "when token is invalid" do
      before do
        stub_request(:get, "#{api_base}/user")
          .to_return(status: 401, body: { message: "Bad credentials" }.to_json)
      end

      it "raises AuthenticationError" do
        expect { client.validate_token }.to raise_error(GithubClient::AuthenticationError)
      end
    end
  end

  describe "#repository" do
    let(:repo) { "owner/repo" }

    context "when repository exists" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}")
          .to_return(
            status: 200,
            body: {
              id: 123,
              name: "repo",
              full_name: repo,
              private: false,
              description: "A test repository"
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns repository data" do
        result = client.repository(repo)

        expect(result.full_name).to eq(repo)
        expect(result.name).to eq("repo")
        expect(result.description).to eq("A test repository")
      end
    end

    context "when repository does not exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}")
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.repository(repo) }.to raise_error(GithubClient::NotFoundError)
      end
    end

    context "when access is denied" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}")
          .to_return(status: 401, body: { message: "Bad credentials" }.to_json)
      end

      it "raises AuthenticationError" do
        expect { client.repository(repo) }.to raise_error(GithubClient::AuthenticationError)
      end
    end
  end

  describe "#repositories" do
    let(:repo_with_push) do
      { id: 1, full_name: "owner/repo1", name: "repo1", private: false,
        default_branch: "main", permissions: { admin: true, push: true, pull: true } }
    end
    let(:repo_without_push) do
      { id: 2, full_name: "owner/repo2", name: "repo2", private: false,
        default_branch: "main", permissions: { admin: false, push: false, pull: true } }
    end

    before do
      stub_request(:get, %r{#{api_base}/user/repos})
        .to_return(
          status: 200,
          body: [ repo_with_push, repo_without_push ].to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "fetches repos via GET /user/repos" do
      result = client.repositories

      expect(result.size).to eq(1)
      expect(result.first.full_name).to eq("owner/repo1")
    end

    it "filters to repos with push access" do
      result = client.repositories

      expect(result.map(&:full_name)).to eq([ "owner/repo1" ])
    end
  end

  describe "#write_accessible?" do
    let(:repo) { "owner/repo" }

    context "when the token has write access" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/git/blobs")
          .to_return(
            status: 201,
            body: { sha: "abc123", url: "#{api_base}/repos/#{repo}/git/blobs/abc123" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns true" do
        expect(client.write_accessible?(repo)).to be true
      end
    end

    context "when the token does not have write access" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/git/blobs")
          .to_return(status: 403, body: { message: "Resource not accessible by personal access token" }.to_json)
      end

      it "returns false" do
        expect(client.write_accessible?(repo)).to be false
      end
    end

    context "when the repo does not exist" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/git/blobs")
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "returns false" do
        expect(client.write_accessible?(repo)).to be false
      end
    end

    context "with repeated calls" do
      it "caches results per repo and does not repeat API calls" do
        stub = stub_request(:post, "#{api_base}/repos/#{repo}/git/blobs")
          .to_return(
            status: 201,
            body: { sha: "abc123", url: "#{api_base}/repos/#{repo}/git/blobs/abc123" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        client.write_accessible?(repo)
        client.write_accessible?(repo)

        expect(stub).to have_been_requested.once
      end
    end
  end

  describe "#issues" do
    let(:repo) { "owner/repo" }

    context "when fetching all open issues" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues")
          .with(query: { state: "open" })
          .to_return(
            status: 200,
            body: [
              { id: 1, number: 1, title: "Issue 1", state: "open" },
              { id: 2, number: 2, title: "Issue 2", state: "open" }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns list of issues" do
        result = client.issues(repo)

        expect(result.size).to eq(2)
        expect(result.first.title).to eq("Issue 1")
      end
    end

    context "when filtering by labels" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues")
          .with(query: { state: "open", labels: "bug,help wanted" })
          .to_return(
            status: 200,
            body: [
              { id: 1, number: 1, title: "Bug Issue", state: "open" }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "filters issues by label string" do
        result = client.issues(repo, labels: "bug,help wanted")

        expect(result.size).to eq(1)
        expect(result.first.title).to eq("Bug Issue")
      end

      it "accepts label array" do
        result = client.issues(repo, labels: [ "bug", "help wanted" ])

        expect(result.size).to eq(1)
      end
    end

    context "when fetching closed issues" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues")
          .with(query: { state: "closed" })
          .to_return(
            status: 200,
            body: [].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns closed issues" do
        result = client.issues(repo, state: "closed")

        expect(result).to eq([])
      end
    end
  end

  describe "#pull_request" do
    let(:repo) { "owner/repo" }

    context "when pull request exists" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/pulls/42")
          .to_return(
            status: 200,
            body: {
              id: 1,
              number: 42,
              title: "Fix the bug",
              state: "open",
              html_url: "https://github.com/#{repo}/pull/42",
              head: { ref: "fix-the-bug", sha: "abc123" },
              base: { ref: "main" }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns pull request data" do
        result = client.pull_request(repo, 42)

        expect(result.number).to eq(42)
        expect(result.head.ref).to eq("fix-the-bug")
        expect(result.base.ref).to eq("main")
      end
    end

    context "when pull request does not exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/pulls/999")
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.pull_request(repo, 999) }.to raise_error(GithubClient::NotFoundError)
      end
    end
  end

  describe "#create_pull_request" do
    let(:repo) { "owner/repo" }

    context "when successful" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/pulls")
          .with(
            body: {
              base: "main",
              head: "feature-branch",
              title: "Add new feature",
              body: "This PR adds a new feature"
            }.to_json
          )
          .to_return(
            status: 201,
            body: {
              id: 1,
              number: 42,
              title: "Add new feature",
              state: "open",
              html_url: "https://github.com/#{repo}/pull/42"
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "creates a pull request" do
        result = client.create_pull_request(
          repo,
          base: "main",
          head: "feature-branch",
          title: "Add new feature",
          body: "This PR adds a new feature"
        )

        expect(result.number).to eq(42)
        expect(result.title).to eq("Add new feature")
      end
    end

    context "when repository not found" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/pulls")
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect {
          client.create_pull_request(repo, base: "main", head: "feature", title: "PR")
        }.to raise_error(GithubClient::NotFoundError)
      end
    end
  end

  describe "#labels" do
    let(:repo) { "owner/repo" }

    before do
      stub_request(:get, "#{api_base}/repos/#{repo}/labels")
        .to_return(
          status: 200,
          body: [
            { id: 1, name: "bug", color: "d73a4a" },
            { id: 2, name: "enhancement", color: "a2eeef" }
          ].to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns list of labels" do
      result = client.labels(repo)

      expect(result.size).to eq(2)
      expect(result.first.name).to eq("bug")
    end
  end

  describe "#create_label" do
    let(:repo) { "owner/repo" }

    before do
      stub_request(:post, "#{api_base}/repos/#{repo}/labels")
        .with(
          body: hash_including("name" => "priority", "color" => "ff0000", "description" => "High priority")
        )
        .to_return(
          status: 201,
          body: { id: 3, name: "priority", color: "ff0000", description: "High priority" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "creates a new label" do
      result = client.create_label(repo, name: "priority", color: "ff0000", description: "High priority")

      expect(result.name).to eq("priority")
      expect(result.color).to eq("ff0000")
    end
  end

  describe "#add_labels_to_issue" do
    let(:repo) { "owner/repo" }
    let(:issue_number) { 1 }

    before do
      stub_request(:post, "#{api_base}/repos/#{repo}/issues/#{issue_number}/labels")
        .with(body: [ "bug", "urgent" ].to_json)
        .to_return(
          status: 200,
          body: [
            { id: 1, name: "bug", color: "d73a4a" },
            { id: 2, name: "urgent", color: "ff0000" }
          ].to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "adds labels to an issue" do
      result = client.add_labels_to_issue(repo, issue_number, [ "bug", "urgent" ])

      expect(result.size).to eq(2)
      expect(result.map(&:name)).to contain_exactly("bug", "urgent")
    end
  end

  describe "#add_comment" do
    let(:repo) { "owner/repo" }
    let(:issue_number) { 1 }

    context "when successful" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/issues/#{issue_number}/comments")
          .with(body: { body: "PR created: https://github.com/owner/repo/pull/42" }.to_json)
          .to_return(
            status: 201,
            body: {
              id: 1,
              body: "PR created: https://github.com/owner/repo/pull/42",
              user: { login: "testuser" }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "creates a comment on the issue" do
        result = client.add_comment(repo, issue_number, "PR created: https://github.com/owner/repo/pull/42")

        expect(result.body).to eq("PR created: https://github.com/owner/repo/pull/42")
      end
    end

    context "when issue does not exist" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/issues/#{issue_number}/comments")
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect {
          client.add_comment(repo, issue_number, "comment")
        }.to raise_error(GithubClient::NotFoundError)
      end
    end
  end

  describe "#remove_label_from_issue" do
    let(:repo) { "owner/repo" }
    let(:issue_number) { 1 }

    before do
      stub_request(:delete, "#{api_base}/repos/#{repo}/issues/#{issue_number}/labels/bug")
        .to_return(
          status: 200,
          body: [
            { id: 2, name: "urgent", color: "ff0000" }
          ].to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "removes a label from an issue" do
      result = client.remove_label_from_issue(repo, issue_number, "bug")

      expect(result.size).to eq(1)
      expect(result.first.name).to eq("urgent")
    end
  end

  describe "#check_runs_for_ref" do
    let(:repo) { "owner/repo" }
    let(:ref) { "abc123" }

    context "when check runs exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/commits/#{ref}/check-runs")
          .to_return(
            status: 200,
            body: {
              total_count: 2,
              check_runs: [
                { id: 1, name: "rspec", conclusion: "failure" },
                { id: 2, name: "rubocop", conclusion: "success" }
              ]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns check run names and conclusions" do
        result = client.check_runs_for_ref(repo, ref)

        expect(result).to eq([
          { name: "rspec", conclusion: "failure" },
          { name: "rubocop", conclusion: "success" }
        ])
      end
    end

    context "when ref does not exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/commits/#{ref}/check-runs")
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.check_runs_for_ref(repo, ref) }.to raise_error(GithubClient::NotFoundError)
      end
    end
  end

  describe "#issue_comments" do
    let(:repo) { "owner/repo" }

    context "when comments exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/comments")
          .to_return(
            status: 200,
            body: [
              { id: 1, body: "Looks good", user: { login: "reviewer" } },
              { id: 2, body: "Please fix", user: { login: "maintainer" } }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns comments" do
        result = client.issue_comments(repo, 42)

        expect(result.size).to eq(2)
        expect(result.first.body).to eq("Looks good")
        expect(result.first.user.login).to eq("reviewer")
      end
    end
  end

  describe "#review_threads" do
    let(:repo) { "owner/repo" }

    context "when threads exist" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                repository: {
                  pullRequest: {
                    reviewThreads: {
                      nodes: [
                        {
                          id: "thread_1",
                          isResolved: false,
                          comments: {
                            nodes: [
                              { body: "Fix this", path: "app/model.rb", line: 10, author: { login: "reviewer" } }
                            ]
                          }
                        },
                        {
                          id: "thread_2",
                          isResolved: true,
                          comments: {
                            nodes: [
                              { body: "Done", path: "app/view.rb", line: 5, author: { login: "author" } }
                            ]
                          }
                        }
                      ]
                    }
                  }
                }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns threads with resolution status and comments" do
        result = client.review_threads(repo, 42)

        expect(result.size).to eq(2)
        expect(result.first[:id]).to eq("thread_1")
        expect(result.first[:is_resolved]).to be false
        expect(result.first[:comments].first[:body]).to eq("Fix this")
        expect(result.first[:comments].first[:path]).to eq("app/model.rb")
        expect(result.first[:comments].first[:line]).to eq(10)
        expect(result.first[:comments].first[:author]).to eq("reviewer")

        expect(result.last[:is_resolved]).to be true
      end
    end
  end

  describe "#pull_request_reviews" do
    let(:repo) { "owner/repo" }

    context "when reviews exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/pulls/42/reviews")
          .to_return(
            status: 200,
            body: [
              {
                id: 1,
                user: { login: "reviewer" },
                state: "CHANGES_REQUESTED",
                submitted_at: "2026-02-20T10:00:00Z"
              },
              {
                id: 2,
                user: { login: "approver" },
                state: "APPROVED",
                submitted_at: "2026-02-21T10:00:00Z"
              }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns reviews with user, state, and submitted_at parsed as Time" do
        result = client.pull_request_reviews(repo, 42)

        expect(result.size).to eq(2)
        expect(result.first[:id]).to eq(1)
        expect(result.first[:user_login]).to eq("reviewer")
        expect(result.first[:state]).to eq("CHANGES_REQUESTED")
        expect(result.first[:submitted_at]).to be_a(Time)
        expect(result.first[:submitted_at]).to eq(Time.parse("2026-02-20T10:00:00Z"))
        expect(result.last[:state]).to eq("APPROVED")
      end
    end

    context "when pull request does not exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/pulls/999/reviews")
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.pull_request_reviews(repo, 999) }.to raise_error(GithubClient::NotFoundError)
      end
    end
  end

  describe "#resolve_review_thread" do
    context "when resolution succeeds" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                resolveReviewThread: {
                  thread: { id: "thread_1", isResolved: true }
                }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "resolves the thread" do
        result = client.resolve_review_thread("thread_1")

        expect(result.dig("data", "resolveReviewThread", "thread", "isResolved")).to be true
      end
    end
  end

  describe "#create_pull_request_comment_reply" do
    let(:repo) { "owner/repo" }

    context "when reply succeeds" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/pulls/42/comments")
          .with(body: { body: "Fixed!", in_reply_to: 100 }.to_json)
          .to_return(
            status: 201,
            body: { id: 200, body: "Fixed!", user: { login: "bot" } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "creates a reply" do
        result = client.create_pull_request_comment_reply(repo, 42, 100, "Fixed!")

        expect(result.body).to eq("Fixed!")
      end
    end
  end

  describe "#rate_limit_remaining" do
    context "when rate limit info is available" do
      it "returns remaining requests" do
        rate_limit = instance_double(Octokit::RateLimit, remaining: 4999)
        allow(client.client).to receive(:rate_limit).and_return(rate_limit)

        expect(client.rate_limit_remaining).to eq(4999)
      end
    end

    context "when rate limit request fails" do
      it "returns 0" do
        allow(client.client).to receive(:rate_limit).and_raise(Octokit::Error)

        expect(client.rate_limit_remaining).to eq(0)
      end
    end
  end

  describe "#rate_limit_low?" do
    context "when remaining is below threshold" do
      it "returns true" do
        rate_limit = instance_double(Octokit::RateLimit, remaining: 5)
        allow(client.client).to receive(:rate_limit).and_return(rate_limit)

        expect(client.rate_limit_low?).to be true
      end
    end

    context "when remaining is above threshold" do
      it "returns false" do
        rate_limit = instance_double(Octokit::RateLimit, remaining: 100)
        allow(client.client).to receive(:rate_limit).and_return(rate_limit)

        expect(client.rate_limit_low?).to be false
      end
    end

    context "with custom threshold" do
      it "returns true when remaining is below custom threshold" do
        rate_limit = instance_double(Octokit::RateLimit, remaining: 50)
        allow(client.client).to receive(:rate_limit).and_return(rate_limit)

        expect(client.rate_limit_low?(threshold: 100)).to be true
      end

      it "returns false when remaining is above custom threshold" do
        rate_limit = instance_double(Octokit::RateLimit, remaining: 50)
        allow(client.client).to receive(:rate_limit).and_return(rate_limit)

        expect(client.rate_limit_low?(threshold: 25)).to be false
      end
    end
  end

  describe "rate limit error handling" do
    let(:repo) { "owner/repo" }
    let(:reset_time) { Time.now.to_i + 3600 }

    before do
      stub_request(:get, "#{api_base}/repos/#{repo}")
        .to_return(
          status: 403,
          body: { message: "API rate limit exceeded" }.to_json,
          headers: { "X-RateLimit-Reset" => reset_time.to_s }
        )

      stub_request(:get, "#{api_base}/rate_limit")
        .to_return(
          status: 200,
          body: {
            resources: {
              core: { limit: 5000, remaining: 0, reset: reset_time }
            },
            rate: { limit: 5000, remaining: 0, reset: reset_time }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "raises RateLimitError with reset time" do
      expect { client.repository(repo) }.to raise_error(GithubClient::RateLimitError) do |error|
        expect(error.reset_at).not_to be_nil
      end
    end
  end

  describe "generic API error handling" do
    let(:repo) { "owner/repo" }

    before do
      stub_request(:get, "#{api_base}/repos/#{repo}")
        .to_return(
          status: 403,
          body: { message: "Repository access blocked" }.to_json
        )

      stub_request(:get, "#{api_base}/rate_limit")
        .to_return(
          status: 200,
          body: {
            resources: { core: { limit: 5000, remaining: 4999, reset: Time.now.to_i } },
            rate: { limit: 5000, remaining: 4999, reset: Time.now.to_i }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "raises ApiError with status code" do
      expect { client.repository(repo) }.to raise_error(GithubClient::ApiError) do |error|
        expect(error.status).to eq(403)
      end
    end
  end
end
