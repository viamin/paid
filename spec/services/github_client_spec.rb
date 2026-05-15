# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubClient do
  let(:token) { "ghp_test_token_123456789012345678901234567890" }
  let(:client) { described_class.new(token: token) }
  let(:api_base) { "https://api.github.com" }

  before do
    stub_const("GithubClient::RETRY_INTERVAL", 0)
    stub_const("GithubClient::RETRY_INTERVAL_RANDOMNESS", 0)
    stub_const("GithubClient::RETRY_BACKOFF_FACTOR", 1)
  end

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

      it "returns nil expires_at for classic PATs without expiration header" do
        result = client.validate_token

        expect(result[:expires_at]).to be_nil
      end
    end

    context "when response includes expiration header" do
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
              "X-OAuth-Scopes" => "",
              "github-authentication-token-expiration" => "2026-07-01 00:00:00 UTC"
            }
          )
      end

      it "returns parsed expires_at from response header" do
        result = client.validate_token

        expect(result[:expires_at]).to be_a(Time)
        expect(result[:expires_at]).to eq(Time.parse("2026-07-01 00:00:00 UTC"))
      end
    end

    context "when expiration header contains an invalid value" do
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
              "X-OAuth-Scopes" => "",
              "github-authentication-token-expiration" => "not-a-date"
            }
          )
      end

      it "returns nil expires_at" do
        result = client.validate_token

        expect(result[:expires_at]).to be_nil
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

  describe "#merge_pull_request" do
    let(:repo) { "owner/repo" }
    let(:merge_url) { "#{api_base}/repos/#{repo}/pulls/42/merge" }

    it "omits commit_message when none is provided" do
      stub = stub_request(:put, merge_url)
        .with do |request|
          body = JSON.parse(request.body)

          expect(body).to include("merge_method" => "squash")
          expect(body).not_to have_key("commit_message")
        end
        .to_return(
          status: 200,
          body: { merged: true }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.merge_pull_request(repo, 42, merge_method: "squash")

      expect(stub).to have_been_requested.once
    end

    it "includes commit_message when provided" do
      stub = stub_request(:put, merge_url)
        .with do |request|
          body = JSON.parse(request.body)

          expect(body).to include(
            "merge_method" => "squash",
            "commit_message" => "Custom merge message"
          )
        end
        .to_return(
          status: 200,
          body: { merged: true }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.merge_pull_request(repo, 42,
        merge_method: "squash",
        commit_message: "Custom merge message")

      expect(stub).to have_been_requested.once
    end
  end

  describe "#dispatch_repository_event" do
    let(:repo) { "owner/repo" }
    let(:dispatch_url) { "#{api_base}/repos/#{repo}/dispatches" }

    it "posts the repository_dispatch event and payload" do
      stub = stub_request(:post, dispatch_url)
        .with(body: {
          event_type: "claude-review",
          client_payload: { pr_number: 42 }
        })
        .to_return(status: 204, body: "", headers: {})

      client.dispatch_repository_event(repo,
        event_type: "claude-review",
        client_payload: { pr_number: 42 })

      expect(stub).to have_been_requested.once
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

  describe "#issue_events" do
    let(:repo) { "owner/repo" }

    before do
      stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/events")
        .with(query: { per_page: 100, page: 1 })
        .to_return(
          status: 200,
          body: [
            { event: "labeled", actor: { login: "viamin" }, label: { name: "paid-build" } }
          ].to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns issue events" do
      result = client.issue_events(repo, 42)

      expect(result.size).to eq(1)
      expect(result.first.event).to eq("labeled")
      expect(result.first.actor.login).to eq("viamin")
      expect(result.first.label.name).to eq("paid-build")
    end

    it "stops after max_pages to avoid unbounded API usage" do
      full_page = Array.new(100) { { event: "labeled", actor: { login: "bot" }, label: { name: "x" } } }

      stub_request(:get, "#{api_base}/repos/#{repo}/issues/99/events")
        .with(query: { per_page: 100, page: 1 })
        .to_return(status: 200, body: full_page.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:get, "#{api_base}/repos/#{repo}/issues/99/events")
        .with(query: { per_page: 100, page: 2 })
        .to_return(status: 200, body: full_page.to_json, headers: { "Content-Type" => "application/json" })

      page3_stub = stub_request(:get, "#{api_base}/repos/#{repo}/issues/99/events")
        .with(query: { per_page: 100, page: 3 })

      result = client.issue_events(repo, 99, max_pages: 2)

      expect(result.size).to eq(200)
      expect(page3_stub).not_to have_been_requested
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

  describe "#create_issue" do
    let(:repo) { "owner/repo" }

    context "when successful" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/issues")
          .with(
            body: hash_including(
              "title" => "Bug report",
              "body" => "There is a bug",
              "labels" => [ "paid-generated" ]
            )
          )
          .to_return(
            status: 201,
            body: {
              id: 1,
              number: 10,
              title: "Bug report",
              state: "open",
              html_url: "https://github.com/#{repo}/issues/10"
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "creates an issue" do
        result = client.create_issue(
          repo,
          title: "Bug report",
          body: "There is a bug",
          labels: [ "paid-generated" ]
        )

        expect(result.number).to eq(10)
        expect(result.title).to eq("Bug report")
      end
    end

    context "when repository not found" do
      before do
        stub_request(:post, "#{api_base}/repos/#{repo}/issues")
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect {
          client.create_issue(repo, title: "Issue")
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
      let(:check_runs_payload) do
        [
          {
            id: 1, name: "rspec", status: "completed", conclusion: "failure",
            html_url: "https://github.com/owner/repo/runs/1",
            details_url: "https://github.com/owner/repo/actions/runs/100/job/1",
            output: { title: "RSpec", summary: "1 failure", text: "role root does not exist" }
          },
          {
            id: 2, name: "rubocop", status: "completed", conclusion: "success",
            html_url: "https://github.com/owner/repo/runs/2",
            details_url: "https://ci.example.com/jobs/2",
            output: { title: "Rubocop", summary: "Clean", text: "" }
          },
          {
            id: 3, name: "integration", status: "in_progress", conclusion: nil,
            html_url: "https://github.com/owner/repo/runs/3",
            details_url: "https://ci.example.com/jobs/3",
            output: nil
          }
        ]
      end

      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/commits/#{ref}/check-runs")
          .with(query: hash_including("per_page" => "100", "page" => "1"))
          .to_return(
            status: 200,
            body: { total_count: check_runs_payload.length, check_runs: check_runs_payload }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns check run names, statuses, conclusions, and URLs" do
        result = client.check_runs_for_ref(repo, ref)

        expect(result.first).to include(
          id: 1,
          name: "rspec",
          conclusion: "failure",
          job_id: "1"
        )
        expect(result.first[:output_text]).to include("1 failure")
        expect(result.second).to include(job_id: nil)
        expect(result.third).to include(output_text: "")
      end
    end

    context "when ref does not exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/commits/#{ref}/check-runs")
          .with(query: hash_including("per_page" => "100", "page" => "1"))
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.check_runs_for_ref(repo, ref) }.to raise_error(GithubClient::NotFoundError)
      end
    end

    context "when check runs span multiple pages" do
      before do
        page1_runs = Array.new(100) { |i| { id: i + 1, name: "check-#{i + 1}", conclusion: "success" } }
        page2_runs = [ { id: 101, name: "check-101", conclusion: "failure" } ]

        stub_request(:get, "#{api_base}/repos/#{repo}/commits/#{ref}/check-runs")
          .with(query: hash_including("per_page" => "100", "page" => "1"))
          .to_return(
            status: 200,
            body: { total_count: 101, check_runs: page1_runs }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:get, "#{api_base}/repos/#{repo}/commits/#{ref}/check-runs")
          .with(query: hash_including("per_page" => "100", "page" => "2"))
          .to_return(
            status: 200,
            body: { total_count: 101, check_runs: page2_runs }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "paginates and collects all check runs" do
        result = client.check_runs_for_ref(repo, ref)

        expect(result.size).to eq(101)
        expect(result.last[:name]).to eq("check-101")
        expect(result.last[:conclusion]).to eq("failure")
      end
    end
  end

  describe "#workflow_runs_for_sha" do
    let(:repo) { "owner/repo" }
    let(:sha) { "abc123" }

    def stub_workflow_runs(workflow_runs, total_count: nil)
      total_count ||= workflow_runs.size
      stub_request(:get, "#{api_base}/repos/#{repo}/actions/runs")
        .with(query: hash_including("head_sha" => sha, "per_page" => "100"))
        .to_return(
          status: 200,
          body: { total_count: total_count, workflow_runs: workflow_runs }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    context "when workflow runs exist" do
      before do
        stub_workflow_runs([
          { id: 11, workflow_id: 1, name: "CI", status: "completed", conclusion: "success",
            head_sha: sha, html_url: "https://github.com/owner/repo/actions/runs/11" },
          { id: 12, workflow_id: 2, name: "Lint", status: "completed", conclusion: "failure",
            head_sha: sha, html_url: "https://github.com/owner/repo/actions/runs/12" }
        ])
      end

      it "returns simplified workflow run hashes for the commit" do
        result = client.workflow_runs_for_sha(repo, sha)

        expect(result).to eq([
          { id: 11, workflow_id: 1, name: "CI", status: "completed", conclusion: "success",
            head_sha: sha, html_url: "https://github.com/owner/repo/actions/runs/11" },
          { id: 12, workflow_id: 2, name: "Lint", status: "completed", conclusion: "failure",
            head_sha: sha, html_url: "https://github.com/owner/repo/actions/runs/12" }
        ])
      end
    end

    context "when 'Re-run all jobs' has produced multiple runs for the same workflow" do
      before do
        # API returns newest first; the most recent re-run succeeded but the
        # original failed run is still present. Without dedup, the failure
        # would block a now-green merge.
        stub_workflow_runs([
          { id: 22, workflow_id: 1, name: "CI", status: "completed", conclusion: "success",
            head_sha: sha, html_url: "https://github.com/owner/repo/actions/runs/22" },
          { id: 11, workflow_id: 1, name: "CI", status: "completed", conclusion: "failure",
            head_sha: sha, html_url: "https://github.com/owner/repo/actions/runs/11" }
        ])
      end

      it "returns only the latest run per workflow_id" do
        result = client.workflow_runs_for_sha(repo, sha)

        expect(result.size).to eq(1)
        expect(result.first).to include(id: 22, conclusion: "success")
      end
    end

    context "when no workflow runs exist for the commit" do
      before { stub_workflow_runs([]) }

      it "returns an empty array" do
        expect(client.workflow_runs_for_sha(repo, sha)).to eq([])
      end
    end

    context "when total_count exceeds the per-page limit" do
      before do
        stub_workflow_runs(
          [ { id: 1, workflow_id: 1, name: "CI", status: "completed", conclusion: "success",
              head_sha: sha, html_url: "https://example" } ],
          total_count: 250
        )
      end

      it "logs a pagination_truncated warning" do
        allow(Rails.logger).to receive(:warn)

        client.workflow_runs_for_sha(repo, sha)

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(message: "github_client.workflow_runs_pagination_truncated", total_count: 250)
        )
      end

      it "appends a non-green sentinel so callers refuse to merge on partial data" do
        allow(Rails.logger).to receive(:warn)

        runs = client.workflow_runs_for_sha(repo, sha)
        sentinel = runs.find { |r| r[:name] == "truncated_results_sentinel" }

        expect(sentinel).to be_present
        expect(sentinel[:conclusion]).to eq("failure")
      end
    end

    context "when the token cannot read Actions" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/actions/runs")
          .with(query: hash_including("head_sha" => sha))
          .to_return(
            status: 403,
            body: { message: "Resource not accessible by personal access token" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError with status 403" do
        expect { client.workflow_runs_for_sha(repo, sha) }
          .to raise_error(GithubClient::ApiError) { |e| expect(e.status).to eq(403) }
      end
    end
  end

  describe "#check_run_log" do
    let(:repo) { "owner/repo" }

    it "fetches GitHub Actions job logs for a check run details URL" do
      stub = stub_request(:get, "#{api_base}/repos/#{repo}/actions/jobs/789/logs")
        .to_return(status: 200, body: "Failure/Error: expected true", headers: { "Content-Type" => "text/plain" })

      result = client.check_run_log(repo, details_url: "https://github.com/owner/repo/actions/runs/456/job/789")

      expect(result).to eq("Failure/Error: expected true")
      expect(stub).to have_been_requested.once
    end

    it "returns an empty string for non-Actions checks" do
      expect(client.check_run_log(repo, details_url: "https://example.com/build/1")).to eq("")
    end
  end

  describe "#rerun_workflow_run_failed_jobs" do
    let(:repo) { "owner/repo" }

    it "posts to the rerun-failed-jobs endpoint" do
      stub = stub_request(:post, "#{api_base}/repos/#{repo}/actions/runs/12345/rerun-failed-jobs")
        .to_return(status: 201, body: "{}", headers: { "Content-Type" => "application/json" })

      result = client.rerun_workflow_run_failed_jobs(repo, "12345")

      expect(result).to be true
      expect(stub).to have_been_requested.once
    end

    it "raises an error when the API returns 403" do
      stub_request(:post, "#{api_base}/repos/#{repo}/actions/runs/12345/rerun-failed-jobs")
        .to_return(status: 403, body: { message: "Forbidden" }.to_json)

      expect { client.rerun_workflow_run_failed_jobs(repo, "12345") }
        .to raise_error(GithubClient::Error)
    end
  end

  describe "#issue_comments" do
    let(:repo) { "owner/repo" }

    context "when comments exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/comments")
          .with(query: hash_including("per_page" => "100"))
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

    context "when fetching comments" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/comments")
          .with(query: hash_including("per_page" => "100"))
          .to_return(
            status: 200,
            body: [ { id: 1, body: "Comment", user: { login: "user" } } ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "temporarily enables auto_paginate and restores it" do
        expect(client.client.auto_paginate).to be false
        client.issue_comments(repo, 42)
        expect(client.client.auto_paginate).to be false
      end
    end
  end

  describe "#recent_issue_comments" do
    let(:repo) { "owner/repo" }

    context "when the comment list fits in a single page" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/comments")
          .with(query: hash_including("per_page" => "100", "page" => "1"))
          .to_return(
            status: 200,
            body: [
              { id: 1, body: "First comment", user: { login: "reviewer" } },
              { id: 2, body: "Second comment", user: { login: "maintainer" } }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns the first-page result without a follow-up request" do
        result = client.recent_issue_comments(repo, 42)

        expect(result.size).to eq(2)
        expect(result.map(&:body)).to contain_exactly("First comment", "Second comment")
        expect(client.client.auto_paginate).to be false
      end

      it "marks the result as single-page" do
        result = client.recent_issue_comments(repo, 42)

        expect(result.multi_page?).to be false
        expect(result.older_pages_available?).to be false
      end
    end

    context "when the comment list spans multiple pages" do
      # The /issues/:number/comments endpoint returns comments in ascending
      # order and ignores sort/direction params, so the first page is the
      # OLDEST comments. To get the most recent comments in a bounded
      # request, recent_issue_comments must follow the Link: last rel.
      before do
        link_header = %(<#{api_base}/repos/#{repo}/issues/42/comments?page=2&per_page=100>; rel="next", ) +
          %(<#{api_base}/repos/#{repo}/issues/42/comments?page=5&per_page=100>; rel="last")

        stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/comments")
          .with(query: hash_including("per_page" => "100", "page" => "1"))
          .to_return(
            status: 200,
            body: [ { id: 1, body: "Very old comment", user: { login: "reviewer" } } ].to_json,
            headers: { "Content-Type" => "application/json", "Link" => link_header }
          )

        stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/comments")
          .with(query: hash_including("per_page" => "100", "page" => "5"))
          .to_return(
            status: 200,
            body: [
              { id: 401, body: "Newer comment", user: { login: "maintainer" } },
              { id: 402, body: "Newest comment", user: { login: "maintainer" } }
            ].to_json,
            headers: {
              "Content-Type" => "application/json",
              "Link" => %(<#{api_base}/repos/#{repo}/issues/42/comments?page=4&per_page=100>; rel="prev")
            }
          )
      end

      it "follows the Link: last rel and returns the last-page comments, not the first" do
        result = client.recent_issue_comments(repo, 42)

        expect(result.size).to eq(2)
        expect(result.map(&:body)).to contain_exactly("Newer comment", "Newest comment")
        expect(result.map(&:body)).not_to include("Very old comment")
      end

      it "marks the result as multi-page with next_older_page_url" do
        result = client.recent_issue_comments(repo, 42)

        expect(result.multi_page?).to be true
        expect(result.older_pages_available?).to be true
        expect(result.next_older_page_url).to eq("#{api_base}/repos/#{repo}/issues/42/comments?page=4&per_page=100")
      end

      it "can include a bounded trailing window of recent pages" do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/comments?page=4&per_page=100")
          .to_return(
            status: 200,
            body: [
              { id: 301, body: "Older recent comment", user: { login: "maintainer" } }
            ].to_json,
            headers: {
              "Content-Type" => "application/json",
              "Link" => %(<#{api_base}/repos/#{repo}/issues/42/comments?page=3&per_page=100>; rel="prev", ) +
                %(<#{api_base}/repos/#{repo}/issues/42/comments?page=5&per_page=100>; rel="next")
            }
          )

        result = client.recent_issue_comments(repo, 42, pages: 2)

        expect(result.map(&:body)).to eq([ "Older recent comment", "Newer comment", "Newest comment" ])
        expect(result.multi_page?).to be true
        expect(result.older_pages_available?).to be true
      end

      it "marks the result when the fetched window already includes the oldest page" do
        stub_request(:get, "#{api_base}/repos/#{repo}/issues/42/comments?page=4&per_page=100")
          .to_return(
            status: 200,
            body: [
              { id: 301, body: "Older recent comment", user: { login: "maintainer" } }
            ].to_json,
            headers: {
              "Content-Type" => "application/json",
              "Link" => %(<#{api_base}/repos/#{repo}/issues/42/comments?page=5&per_page=100>; rel="next")
            }
          )

        result = client.recent_issue_comments(repo, 42, pages: 5)

        expect(result.map(&:body)).to eq([ "Older recent comment", "Newer comment", "Newest comment" ])
        expect(result.multi_page?).to be true
        expect(result.older_pages_available?).to be false
        expect(result.next_older_page_url).to be_nil
      end
    end
  end

  describe "#fetch_issue_comment_page" do
    let(:repo) { "owner/repo" }

    it "fetches a single page by URL and exposes pagination metadata" do
      page_url = "#{api_base}/repos/#{repo}/issues/42/comments?page=3&per_page=100"
      prev_url = "#{api_base}/repos/#{repo}/issues/42/comments?page=2&per_page=100"

      stub_request(:get, page_url)
        .to_return(
          status: 200,
          body: [
            { id: 301, body: "Page 3 comment", user: { login: "dev" } }
          ].to_json,
          headers: {
            "Content-Type" => "application/json",
            "Link" => %(<#{prev_url}>; rel="prev")
          }
        )

      result = client.fetch_issue_comment_page(page_url)

      expect(result.size).to eq(1)
      expect(result.first.body).to eq("Page 3 comment")
      expect(result.older_pages_available?).to be true
      expect(result.next_older_page_url).to eq(prev_url)
    end

    it "returns nil next_older_page_url when no prev link exists" do
      page_url = "#{api_base}/repos/#{repo}/issues/42/comments?page=1&per_page=100"

      stub_request(:get, page_url)
        .to_return(
          status: 200,
          body: [
            { id: 1, body: "First page comment", user: { login: "dev" } }
          ].to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = client.fetch_issue_comment_page(page_url)

      expect(result.older_pages_available?).to be false
      expect(result.next_older_page_url).to be_nil
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
          .with(query: hash_including("per_page" => "100"))
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
            headers: {
              "Content-Type" => "application/json",
              "Link" => "<#{api_base}/repos/#{repo}/pulls/42/reviews?page=2>; rel=\"next\""
            }
          )

        stub_request(:get, "#{api_base}/repos/#{repo}/pulls/42/reviews")
          .with(query: hash_including("page" => "2", "per_page" => "100"))
          .to_return(
            status: 200,
            body: [
              {
                id: 3,
                user: { login: "commenter" },
                state: "COMMENTED",
                submitted_at: "2026-02-22T10:00:00Z"
              }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns reviews from all pages with user, state, and submitted_at parsed as Time" do
        result = client.pull_request_reviews(repo, 42)

        expect(result.size).to eq(3)
        expect(result.first[:id]).to eq(1)
        expect(result.first[:user_login]).to eq("reviewer")
        expect(result.first[:state]).to eq("CHANGES_REQUESTED")
        expect(result.first[:submitted_at]).to be_a(Time)
        expect(result.first[:submitted_at]).to eq(Time.parse("2026-02-20T10:00:00Z"))
        expect(result.last[:state]).to eq("COMMENTED")
        expect(result.last[:user_login]).to eq("commenter")
      end

      it "temporarily enables auto_paginate and restores it" do
        expect(client.client.auto_paginate).to be false

        client.pull_request_reviews(repo, 42)

        expect(client.client.auto_paginate).to be false
      end
    end

    context "when pull request does not exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/pulls/999/reviews")
          .with(query: hash_including("per_page" => "100"))
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.pull_request_reviews(repo, 999) }.to raise_error(GithubClient::NotFoundError)
      end
    end
  end

  describe "#pull_request_files" do
    let(:repo) { "owner/repo" }

    context "when files exist" do
      before do
        stub_request(:get, %r{#{api_base}/repos/#{repo}/pulls/42/files})
          .to_return(
            status: 200,
            body: [
              { sha: "abc", filename: "app/models/user.rb", status: "modified" },
              { sha: "def", filename: "config/routes.rb", status: "added" }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns an array of file paths" do
        result = client.pull_request_files(repo, 42)

        expect(result).to eq(%w[app/models/user.rb config/routes.rb])
      end
    end

    context "when files span multiple pages" do
      before do
        stub_request(:get, %r{#{api_base}/repos/#{repo}/pulls/42/files})
          .with(query: hash_excluding("page" => "2"))
          .to_return(
            status: 200,
            body: [
              { sha: "abc", filename: "app/models/user.rb", status: "modified" }
            ].to_json,
            headers: {
              "Content-Type" => "application/json",
              "Link" => "<#{api_base}/repos/#{repo}/pulls/42/files?page=2>; rel=\"next\""
            }
          )

        stub_request(:get, %r{#{api_base}/repos/#{repo}/pulls/42/files})
          .with(query: hash_including("page" => "2"))
          .to_return(
            status: 200,
            body: [
              { sha: "def", filename: "config/routes.rb", status: "added" },
              { sha: "ghi", filename: "lib/tasks/cleanup.rake", status: "removed" }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns file paths from all pages" do
        result = client.pull_request_files(repo, 42)

        expect(result).to eq(%w[app/models/user.rb config/routes.rb lib/tasks/cleanup.rake])
      end
    end

    context "when pull request does not exist" do
      before do
        stub_request(:get, %r{#{api_base}/repos/#{repo}/pulls/999/files})
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.pull_request_files(repo, 999) }.to raise_error(GithubClient::NotFoundError)
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

  describe "#resolve_review_threads_batch" do
    context "when all threads resolve successfully" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                resolve_0: { thread: { id: "thread_1", isResolved: true } },
                resolve_1: { thread: { id: "thread_2", isResolved: true } }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns all threads as resolved" do
        result = client.resolve_review_threads_batch(%w[thread_1 thread_2])

        expect(result[:resolved]).to eq(%w[thread_1 thread_2])
        expect(result[:failed]).to be_empty
      end
    end

    context "when some threads fail" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                resolve_0: { thread: { id: "thread_1", isResolved: true } },
                resolve_1: nil
              },
              errors: [
                { message: "Thread not found", path: [ "resolve_1" ] }
              ]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "reports partial success" do
        result = client.resolve_review_threads_batch(%w[thread_1 thread_2])

        expect(result[:resolved]).to eq(%w[thread_1])
        expect(result[:failed].size).to eq(1)
        expect(result[:failed].first[:id]).to eq("thread_2")
        expect(result[:failed].first[:error]).to include("Thread not found")
      end
    end

    context "when thread resolution is not confirmed" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                resolve_0: { thread: { id: "thread_1", isResolved: true } },
                resolve_1: { thread: { id: "thread_2", isResolved: false } }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "reports unconfirmed threads as failed" do
        result = client.resolve_review_threads_batch(%w[thread_1 thread_2])

        expect(result[:resolved]).to eq(%w[thread_1])
        expect(result[:failed].size).to eq(1)
        expect(result[:failed].first[:id]).to eq("thread_2")
        expect(result[:failed].first[:error]).to eq("Thread not confirmed as resolved")
      end
    end

    context "when called with empty list" do
      it "returns empty results without making API calls" do
        result = client.resolve_review_threads_batch([])

        expect(result).to eq(resolved: [], failed: [])
      end
    end
  end

  describe "#remove_labels_from_issue" do
    let(:repo) { "owner/repo" }
    let(:issue_number) { 1 }

    before do
      stub_request(:delete, "#{api_base}/repos/#{repo}/issues/#{issue_number}/labels/bug")
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:delete, "#{api_base}/repos/#{repo}/issues/#{issue_number}/labels/wontfix")
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
    end

    it "removes all specified labels" do
      result = client.remove_labels_from_issue(repo, issue_number, %w[bug wontfix])

      expect(result[:removed]).to eq(%w[bug wontfix])
      expect(result[:failed]).to be_empty
    end

    context "when some labels fail" do
      before do
        stub_request(:delete, "#{api_base}/repos/#{repo}/issues/#{issue_number}/labels/missing")
          .to_return(status: 404, body: { message: "Not Found" }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "continues past failures and reports them" do
        result = client.remove_labels_from_issue(repo, issue_number, %w[bug missing wontfix])

        expect(result[:removed]).to eq(%w[bug wontfix])
        expect(result[:failed].size).to eq(1)
        expect(result[:failed].first[:label]).to eq("missing")
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

  describe "#dismiss_pull_request_review", :no_db do
    let(:repo) { "owner/repo" }
    let(:dismiss_url) { "#{api_base}/repos/#{repo}/pulls/42/reviews/100/dismissals" }
    let(:message) { "Subsequent review found no remaining actionable issues." }

    before do
      stub_request(:put, dismiss_url)
        .with(body: { message: message }.to_json)
        .to_return(
          status: 200,
          body: { id: 100, state: "DISMISSED" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "sends the dismissal message in the request body" do
      result = client.dismiss_pull_request_review(repo, 42, 100, message: message)

      expect(result.state).to eq("DISMISSED")
      expect(a_request(:put, dismiss_url).with(body: { message: message }.to_json)).to have_been_made.once
    end
  end

  describe "#request_bot_review" do
    let(:repo) { "owner/repo" }
    let(:pr_node_id) { "PR_kwDOTest123" }
    let(:bot_node_id) { "BOT_NODE_ID_TEST_123" }

    context "when request succeeds" do
      let!(:graphql_stub) do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                repository: { pullRequest: { id: pr_node_id } }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              data: {
                requestReviews: { pullRequest: { id: pr_node_id } }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "sends the correct bot node IDs via GraphQL" do
        result = client.request_bot_review(repo, 42, bot_node_ids: [ bot_node_id ])

        expect(result.dig("data", "requestReviews", "pullRequest", "id")).to eq(pr_node_id)
        expect(graphql_stub).to have_been_requested.twice
      end

      it "includes botIds in the mutation variables" do
        client.request_bot_review(repo, 42, bot_node_ids: [ bot_node_id ])

        expect(
          a_request(:post, "#{api_base}/graphql")
            .with { |req|
              body = JSON.parse(req.body)
              body["query"].include?("requestReviews") &&
                body["variables"]["botIds"] == [ bot_node_id ] &&
                body["variables"]["pullRequestId"] == pr_node_id
            }
        ).to have_been_made.once
      end
    end

    context "when PR is not found" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: { repository: { pullRequest: nil } }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises NotFoundError" do
        expect {
          client.request_bot_review(repo, 999, bot_node_ids: [ bot_node_id ])
        }.to raise_error(GithubClient::NotFoundError, /999/)
      end
    end

    context "when GraphQL returns errors" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                repository: { pullRequest: { id: pr_node_id } }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              errors: [ { message: "Copilot not available for this repository" } ]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError with status 422 for unprocessable messages" do
        expect {
          client.request_bot_review(repo, 42, bot_node_ids: [ bot_node_id ])
        }.to raise_error(GithubClient::ApiError) { |e|
          expect(e.status).to eq(422)
          expect(e.message).to include("not available")
        }
      end
    end

    context "when GraphQL returns a generic error" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                repository: { pullRequest: { id: pr_node_id } }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              errors: [ { message: "Something went wrong" } ]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError with nil status" do
        expect {
          client.request_bot_review(repo, 42, bot_node_ids: [ bot_node_id ])
        }.to raise_error(GithubClient::ApiError) { |e|
          expect(e.status).to be_nil
        }
      end
    end

    context "when GraphQL returns errors during node ID lookup" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              errors: [ { message: "Resource not accessible by integration" } ]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError instead of NotFoundError" do
        expect {
          client.request_bot_review(repo, 42, bot_node_ids: [ bot_node_id ])
        }.to raise_error(GithubClient::ApiError, /not accessible/)
      end
    end
  end

  describe "REST retry middleware" do
    let(:repo) { "owner/repo" }

    it "retries on 503 and succeeds" do
      stub_request(:get, "#{api_base}/repos/#{repo}")
        .to_return(
          { status: 503, body: "Service Unavailable" },
          { status: 200, body: { full_name: repo }.to_json, headers: { "Content-Type" => "application/json" } }
        )

      result = client.repository(repo)
      expect(result.full_name).to eq(repo)
    end

    it "retries on 502 and succeeds" do
      stub_request(:get, "#{api_base}/repos/#{repo}")
        .to_return(
          { status: 502, body: "Bad Gateway" },
          { status: 200, body: { full_name: repo }.to_json, headers: { "Content-Type" => "application/json" } }
        )

      result = client.repository(repo)
      expect(result.full_name).to eq(repo)
    end
  end

  describe "GraphQL retry middleware" do
    let(:repo) { "owner/repo" }

    it "retries on 503 and succeeds" do
      stub_request(:post, "#{api_base}/graphql")
        .to_return(
          { status: 503, body: "Service Unavailable" },
          {
            status: 200,
            body: {
              data: {
                repository: {
                  pullRequest: {
                    reviewThreads: { nodes: [] }
                  }
                }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          }
        )

      result = client.review_threads(repo, 1)
      expect(result).to eq([])
    end

    it "retries on 429 and succeeds" do
      stub_request(:post, "#{api_base}/graphql")
        .to_return(
          { status: 429, body: "Rate limited" },
          {
            status: 200,
            body: {
              data: {
                repository: {
                  pullRequest: {
                    reviewThreads: { nodes: [] }
                  }
                }
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          }
        )

      result = client.review_threads(repo, 1)
      expect(result).to eq([])
    end

    it "raises after exhausting retries" do
      stub_request(:post, "#{api_base}/graphql")
        .to_return(status: 502, body: "Bad Gateway")

      expect { client.review_threads(repo, 1) }.to raise_error(GithubClient::ApiError)
    end

    it "does not retry mutations" do
      stub = stub_request(:post, "#{api_base}/graphql")
        .to_return(status: 503, body: "Service Unavailable")

      expect { client.resolve_review_thread("thread_id") }.to raise_error(GithubClient::ApiError)
      expect(stub).to have_been_requested.once
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

  describe "#rate_limit_remaining!" do
    it "returns remaining requests" do
      rate_limit = instance_double(Octokit::RateLimit, remaining: 4999)
      allow(client.client).to receive(:rate_limit).and_return(rate_limit)

      expect(client.rate_limit_remaining!).to eq(4999)
    end

    it "raises on transport/auth failure instead of returning 0" do
      allow(client.client).to receive(:rate_limit).and_raise(Octokit::Unauthorized)

      expect { client.rate_limit_remaining! }.to raise_error(Octokit::Unauthorized)
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

  describe "#code_scanning_alerts" do
    let(:repo) { "owner/repo" }

    context "when alerts exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/code-scanning/alerts")
          .with(query: hash_including("state" => "open"))
          .to_return(
            status: 200,
            body: [
              {
                number: 1667,
                state: "open",
                html_url: "https://github.com/owner/repo/security/code-scanning/1667",
                created_at: "2026-03-29T10:00:00Z",
                updated_at: "2026-03-29T12:00:00Z",
                rule: {
                  id: "py/sensitive-get-query",
                  description: "Sensitive data read from GET request",
                  security_severity_level: "high"
                },
                tool: { name: "CodeQL" },
                most_recent_instance: {
                  message: { text: "Reading sensitive data from a GET request." }
                }
              }
            ].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns parsed alert data" do
        result = client.code_scanning_alerts(repo)

        expect(result.size).to eq(1)
        alert = result.first
        expect(alert[:number]).to eq(1667)
        expect(alert[:state]).to eq("open")
        expect(alert[:severity]).to eq("high")
        expect(alert[:rule_id]).to eq("py/sensitive-get-query")
        expect(alert[:rule_description]).to eq("Sensitive data read from GET request")
        expect(alert[:tool_name]).to eq("CodeQL")
        expect(alert[:summary]).to eq("Reading sensitive data from a GET request.")
      end

      it "returns timestamps as Time objects" do
        alert = client.code_scanning_alerts(repo).first

        expect(alert[:created_at]).to be_a(Time)
        expect(alert[:created_at].iso8601).to eq("2026-03-29T10:00:00Z")
        expect(alert[:updated_at]).to be_a(Time)
      end
    end

    context "when code scanning is not enabled" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/code-scanning/alerts")
          .with(query: hash_including("state" => "open"))
          .to_return(status: 404, body: { message: "Not Found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.code_scanning_alerts(repo) }.to raise_error(GithubClient::NotFoundError)
      end
    end

    context "when no alerts exist" do
      before do
        stub_request(:get, "#{api_base}/repos/#{repo}/code-scanning/alerts")
          .with(query: hash_including("state" => "open"))
          .to_return(
            status: 200,
            body: [].to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns an empty array" do
        result = client.code_scanning_alerts(repo)

        expect(result).to eq([])
      end
    end
  end

  describe "#review_comment_reactions_batch" do
    let(:repo) { "owner/repo" }

    context "when reactions exist" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                repository: {
                  pullRequest: {
                    threads: {
                      pageInfo: { hasNextPage: false },
                      nodes: [
                        {
                          comments: {
                            pageInfo: { hasNextPage: false },
                            nodes: [
                              {
                                databaseId: 101,
                                reactions: {
                                  pageInfo: { hasNextPage: false },
                                  nodes: [
                                    { user: { login: "alice" }, content: "THUMBS_UP", createdAt: "2024-01-01T00:00:00Z" }
                                  ]
                                }
                              }
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

      it "returns reactions from all review comments" do
        result = client.review_comment_reactions_batch(repo, 1)

        expect(result.size).to eq(1)
        expect(result.first[:user_login]).to eq("alice")
        expect(result.first[:content]).to eq("+1")
      end
    end

    context "when GraphQL returns errors" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              errors: [ { message: "rate limited" } ]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError instead of returning empty results" do
        expect { client.review_comment_reactions_batch(repo, 1) }
          .to raise_error(GithubClient::ApiError, /rate limited/)
      end
    end

    context "when a comment has more than 100 reactions (paginated)" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                repository: {
                  pullRequest: {
                    threads: {
                      pageInfo: { hasNextPage: false },
                      nodes: [
                        {
                          comments: {
                            pageInfo: { hasNextPage: false },
                            nodes: [
                              {
                                databaseId: 202,
                                reactions: {
                                  pageInfo: { hasNextPage: true },
                                  nodes: Array.new(100) { |i|
                                    { user: { login: "user#{i}" }, content: "THUMBS_UP", createdAt: "2024-01-01T00:00:00Z" }
                                  }
                                }
                              }
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

        stub_request(:get, "#{api_base}/repos/owner/repo/pulls/comments/202/reactions")
          .to_return(
            status: 200,
            body: Array.new(105) { |i|
              { user: { login: "user#{i}" }, content: "+1", created_at: "2024-01-01T00:00:00Z" }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "falls back to REST API for the overflowing comment" do
        result = client.review_comment_reactions_batch(repo, 1)

        expect(result.size).to eq(105)
        expect(WebMock).to have_requested(:get, "#{api_base}/repos/owner/repo/pulls/comments/202/reactions")
      end
    end

    context "when review threads are truncated" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                repository: {
                  pullRequest: {
                    threads: {
                      pageInfo: { hasNextPage: true },
                      nodes: [
                        {
                          comments: {
                            pageInfo: { hasNextPage: true },
                            nodes: [
                              {
                                databaseId: 401,
                                reactions: {
                                  pageInfo: { hasNextPage: false },
                                  nodes: [
                                    { user: { login: "alice" }, content: "THUMBS_UP", createdAt: "2024-01-01T00:00:00Z" }
                                  ]
                                }
                              }
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

      it "logs warnings for truncated threads and comments" do
        expect(Rails.logger).to receive(:warn).with(hash_including(
          message: "github_client.review_threads_truncated"
        ))
        expect(Rails.logger).to receive(:warn).with(hash_including(
          message: "github_client.review_thread_comments_truncated"
        ))

        result = client.review_comment_reactions_batch(repo, 1)
        expect(result.size).to eq(1)
      end
    end

    context "when REST fallback fails for one comment but others succeed" do
      before do
        stub_request(:post, "#{api_base}/graphql")
          .to_return(
            status: 200,
            body: {
              data: {
                repository: {
                  pullRequest: {
                    threads: {
                      pageInfo: { hasNextPage: false },
                      nodes: [
                        {
                          comments: {
                            pageInfo: { hasNextPage: false },
                            nodes: [
                              {
                                databaseId: 301,
                                reactions: {
                                  pageInfo: { hasNextPage: true },
                                  nodes: []
                                }
                              },
                              {
                                databaseId: 302,
                                reactions: {
                                  pageInfo: { hasNextPage: false },
                                  nodes: [
                                    { user: { login: "bob" }, content: "THUMBS_UP", createdAt: "2024-01-01T00:00:00Z" }
                                  ]
                                }
                              }
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

        stub_request(:get, "#{api_base}/repos/owner/repo/pulls/comments/301/reactions")
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "returns reactions from successful comments and skips the failed one" do
        result = client.review_comment_reactions_batch(repo, 1)

        expect(result.size).to eq(1)
        expect(result.first[:user_login]).to eq("bob")
      end
    end
  end

  describe "GitHub health state integration" do
    it "records a failure on server errors" do
      stub_request(:get, "#{api_base}/user")
        .to_return(status: 500,
          body: { message: "Internal Server Error" }.to_json,
          headers: { "Content-Type" => "application/json" })

      state = create(:github_health_state)

      expect { client.validate_token }.to raise_error(GithubClient::ApiError)
      expect(state.reload.failure_count).to be >= 1
    end

    it "records a success on successful calls" do
      stub_request(:get, "#{api_base}/user")
        .to_return(
          status: 200,
          body: { login: "testuser", id: 1, name: "Test", email: "t@t.com" }.to_json,
          headers: { "Content-Type" => "application/json", "X-OAuth-Scopes" => "repo" }
        )

      state = create(:github_health_state, failure_count: 3)

      client.validate_token

      expect(state.reload.failure_count).to eq(0)
    end

    it "does not record a failure on 404 errors" do
      stub_request(:get, "#{api_base}/repos/owner/repo")
        .to_return(status: 404, body: { message: "Not Found" }.to_json, headers: { "Content-Type" => "application/json" })

      state = create(:github_health_state)

      expect { client.repository("owner/repo") }.to raise_error(GithubClient::NotFoundError)
      expect(state.reload.failure_count).to eq(0)
    end
  end
end
