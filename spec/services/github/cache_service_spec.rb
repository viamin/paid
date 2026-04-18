# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Github::CacheService do
  let(:github_client) { instance_double(GithubClient) }
  let(:cache_service) { described_class.new(client: github_client) }
  let(:repo) { "owner/repo" }

  around do |example|
    # Use memory store so cache operations work in tests
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe "#repository" do
    let(:repo_data) { OpenStruct.new(id: 1, name: "repo", full_name: repo) }

    before do
      allow(github_client).to receive(:repository).with(repo).and_return(repo_data)
    end

    it "returns repository data" do
      expect(cache_service.repository(repo)).to eq(repo_data)
    end

    it "caches the result on subsequent calls" do
      cache_service.repository(repo)
      cache_service.repository(repo)

      expect(github_client).to have_received(:repository).once
    end

    it "instruments a cache miss on first call" do
      events = []
      ActiveSupport::Notifications.subscribe("github_cache.miss") { |e| events << e }

      cache_service.repository(repo)

      expect(events.size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe("github_cache.miss")
    end

    it "instruments a cache hit on subsequent calls" do
      events = []
      ActiveSupport::Notifications.subscribe("github_cache.hit") { |e| events << e }

      cache_service.repository(repo)
      cache_service.repository(repo)

      expect(events.size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe("github_cache.hit")
    end
  end

  describe "#issue" do
    let(:issue_data) { OpenStruct.new(number: 42, title: "Bug") }

    before do
      allow(github_client).to receive(:issue).with(repo, 42).and_return(issue_data)
    end

    it "returns issue data" do
      expect(cache_service.issue(repo, 42)).to eq(issue_data)
    end

    it "caches the result" do
      cache_service.issue(repo, 42)
      cache_service.issue(repo, 42)

      expect(github_client).to have_received(:issue).once
    end
  end

  describe "#pull_request" do
    let(:pr_data) { OpenStruct.new(number: 10, title: "Feature") }

    before do
      allow(github_client).to receive(:pull_request).with(repo, 10).and_return(pr_data)
    end

    it "returns pull request data" do
      expect(cache_service.pull_request(repo, 10)).to eq(pr_data)
    end

    it "caches the result" do
      cache_service.pull_request(repo, 10)
      cache_service.pull_request(repo, 10)

      expect(github_client).to have_received(:pull_request).once
    end
  end

  describe "#issues" do
    let(:issues_data) { [ OpenStruct.new(number: 1), OpenStruct.new(number: 2) ] }

    before do
      allow(github_client).to receive(:issues)
        .with(repo, labels: nil, state: "open")
        .and_return(issues_data)
    end

    it "returns issues list" do
      expect(cache_service.issues(repo)).to eq(issues_data)
    end

    it "caches the result" do
      cache_service.issues(repo)
      cache_service.issues(repo)

      expect(github_client).to have_received(:issues).once
    end

    it "caches separately for different label filters" do
      allow(github_client).to receive(:issues)
        .with(repo, labels: "bug", state: "open")
        .and_return([ issues_data.first ])

      cache_service.issues(repo)
      cache_service.issues(repo, labels: "bug")

      expect(github_client).to have_received(:issues).twice
    end

    it "caches separately for different options" do
      allow(github_client).to receive(:issues)
        .with(repo, labels: nil, state: "open", per_page: 50)
        .and_return([ issues_data.first ])

      cache_service.issues(repo)
      cache_service.issues(repo, per_page: 50)

      expect(github_client).to have_received(:issues).twice
    end
  end

  describe "#pull_requests" do
    let(:prs_data) { [ OpenStruct.new(number: 5) ] }

    before do
      allow(github_client).to receive(:pull_requests)
        .with(repo, state: "open")
        .and_return(prs_data)
    end

    it "returns pull requests list" do
      expect(cache_service.pull_requests(repo, state: "open")).to eq(prs_data)
    end

    it "caches the result" do
      cache_service.pull_requests(repo, state: "open")
      cache_service.pull_requests(repo, state: "open")

      expect(github_client).to have_received(:pull_requests).once
    end
  end

  describe "#labels" do
    let(:labels_data) { [ OpenStruct.new(name: "bug"), OpenStruct.new(name: "feature") ] }

    before do
      allow(github_client).to receive(:labels).with(repo).and_return(labels_data)
    end

    it "returns labels" do
      expect(cache_service.labels(repo)).to eq(labels_data)
    end

    it "caches the result" do
      cache_service.labels(repo)
      cache_service.labels(repo)

      expect(github_client).to have_received(:labels).once
    end
  end

  describe "#invalidate_repo" do
    it "clears all cached data for the repo" do
      allow(github_client).to receive(:repository).with(repo).and_return("original_repo")
      allow(github_client).to receive(:issue).with(repo, 1).and_return("original_issue")
      allow(github_client).to receive(:pull_request).with(repo, 2).and_return("original_pr")

      cache_service.repository(repo)
      cache_service.issue(repo, 1)
      cache_service.pull_request(repo, 2)

      cache_service.invalidate_repo(repo)

      allow(github_client).to receive(:repository).with(repo).and_return("fresh_repo")
      allow(github_client).to receive(:issue).with(repo, 1).and_return("fresh_issue")
      allow(github_client).to receive(:pull_request).with(repo, 2).and_return("fresh_pr")

      expect(cache_service.repository(repo)).to eq("fresh_repo")
      expect(cache_service.issue(repo, 1)).to eq("fresh_issue")
      expect(cache_service.pull_request(repo, 2)).to eq("fresh_pr")
    end
  end

  describe "#invalidate_issue" do
    it "clears the cached issue" do
      allow(github_client).to receive(:issue).with(repo, 42).and_return("original")
      cache_service.issue(repo, 42)
      cache_service.invalidate_issue(repo, 42)

      allow(github_client).to receive(:issue).with(repo, 42).and_return("fresh")
      expect(cache_service.issue(repo, 42)).to eq("fresh")
    end

    it "does not clear the cached pull request" do
      allow(github_client).to receive(:pull_request).with(repo, 10).and_return("cached_pr")
      cache_service.pull_request(repo, 10)

      cache_service.invalidate_issue(repo, 42)

      expect(cache_service.pull_request(repo, 10)).to eq("cached_pr")
      expect(github_client).to have_received(:pull_request).once
    end

    it "does not clear the cached repository metadata" do
      allow(github_client).to receive(:repository).with(repo).and_return("cached_repo")
      cache_service.repository(repo)

      cache_service.invalidate_issue(repo, 42)

      expect(cache_service.repository(repo)).to eq("cached_repo")
      expect(github_client).to have_received(:repository).once
    end

    it "instruments the invalidation" do
      events = []
      ActiveSupport::Notifications.subscribe("github_cache.invalidate") { |e| events << e }

      cache_service.invalidate_issue(repo, 42)

      expect(events.size).to eq(1)
      expect(events.first.payload[:scope]).to eq(:issue)
    ensure
      ActiveSupport::Notifications.unsubscribe("github_cache.invalidate")
    end
  end

  describe "#invalidate_pull_request" do
    it "clears the cached pull request" do
      allow(github_client).to receive(:pull_request).with(repo, 10).and_return("original")
      cache_service.pull_request(repo, 10)
      cache_service.invalidate_pull_request(repo, 10)

      allow(github_client).to receive(:pull_request).with(repo, 10).and_return("fresh")
      expect(cache_service.pull_request(repo, 10)).to eq("fresh")
    end

    it "does not clear the cached issue" do
      allow(github_client).to receive(:issue).with(repo, 42).and_return("cached_issue")
      cache_service.issue(repo, 42)

      cache_service.invalidate_pull_request(repo, 10)

      expect(cache_service.issue(repo, 42)).to eq("cached_issue")
      expect(github_client).to have_received(:issue).once
    end

    it "does not clear the cached repository metadata" do
      allow(github_client).to receive(:repository).with(repo).and_return("cached_repo")
      cache_service.repository(repo)

      cache_service.invalidate_pull_request(repo, 10)

      expect(cache_service.repository(repo)).to eq("cached_repo")
      expect(github_client).to have_received(:repository).once
    end
  end

  describe "unknown methods" do
    it "raises NoMethodError" do
      expect { cache_service.rate_limit_remaining }.to raise_error(NoMethodError)
    end

    it "does not respond to client methods" do
      expect(cache_service).not_to respond_to(:rate_limit_remaining)
    end
  end
end
