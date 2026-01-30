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
          body: { name: "priority", color: "ff0000", description: "High priority" }.to_json
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

  describe "#rate_limit_remaining" do
    context "when rate limit info is available" do
      before do
        stub_request(:get, "#{api_base}/rate_limit")
          .to_return(
            status: 200,
            body: {
              resources: {
                core: { limit: 5000, remaining: 4999, reset: Time.now.to_i + 3600 }
              },
              rate: { limit: 5000, remaining: 4999, reset: Time.now.to_i + 3600 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns remaining requests" do
        expect(client.rate_limit_remaining).to eq(4999)
      end
    end

    context "when rate limit request fails" do
      before do
        stub_request(:get, "#{api_base}/rate_limit")
          .to_return(status: 500)
      end

      it "returns 0" do
        expect(client.rate_limit_remaining).to eq(0)
      end
    end
  end

  describe "#rate_limit_low?" do
    before do
      stub_request(:get, "#{api_base}/rate_limit")
        .to_return(
          status: 200,
          body: {
            resources: {
              core: { limit: 5000, remaining: remaining, reset: Time.now.to_i + 3600 }
            },
            rate: { limit: 5000, remaining: remaining, reset: Time.now.to_i + 3600 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    context "when remaining is below threshold" do
      let(:remaining) { 5 }

      it "returns true" do
        expect(client.rate_limit_low?).to be true
      end
    end

    context "when remaining is above threshold" do
      let(:remaining) { 100 }

      it "returns false" do
        expect(client.rate_limit_low?).to be false
      end
    end

    context "with custom threshold" do
      let(:remaining) { 50 }

      it "respects custom threshold" do
        expect(client.rate_limit_low?(threshold: 100)).to be true
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
