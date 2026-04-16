# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Automation::Providers::Github::ReviewProvider do
  let(:project_class) do
    Class.new do
      def full_name = "acme/widgets"
    end
  end

  let(:client) { instance_double(GithubClient) }
  let(:project) { project_class.new }
  let(:adapter) { described_class.new(project, client: client) }

  it "conforms to the ReviewProvider interface" do
    expect(described_class.ancestors).to include(Automation::Providers::ReviewProvider)
  end

  describe "#fetch_reviews" do
    it "normalizes reviews into Data::Review" do
      expect(client).to receive(:pull_request_reviews)
        .with("acme/widgets", 42)
        .and_return([
          {
            id: 1, user_login: "Alice", state: "APPROVED",
            body: "lgtm", submitted_at: Time.utc(2026, 1, 1), commit_id: "abc123"
          }
        ])

      result = adapter.fetch_reviews(repo: "acme/widgets", pr_number: 42)

      expect(result.first).to be_a(Automation::Providers::Data::Review)
      expect(result.first.state).to eq(:approved)
      expect(result.first.raw_state).to eq("APPROVED")
      expect(result.first.author_login).to eq("alice")
      expect(result.first.commit_sha).to eq("abc123")
    end

    it "maps unknown states to :commented" do
      expect(client).to receive(:pull_request_reviews)
        .and_return([ { id: 1, user_login: "a", state: "SOMETHING", body: "", submitted_at: nil, commit_id: nil } ])

      result = adapter.fetch_reviews(repo: "acme/widgets", pr_number: 42)

      expect(result.first.state).to eq(:commented)
    end
  end

  describe "#fetch_review_threads" do
    it "normalizes threads and thread comments" do
      expect(client).to receive(:review_threads).with("acme/widgets", 42).and_return([
        {
          id: "thread1",
          is_resolved: false,
          comments: [
            { body: "nit", path: "app/x.rb", line: 3, author: "Alice" }
          ]
        }
      ])

      result = adapter.fetch_review_threads(repo: "acme/widgets", pr_number: 42)

      expect(result.first).to be_a(Automation::Providers::Data::ReviewThread)
      expect(result.first.id).to eq("thread1")
      expect(result.first.resolved).to be false
      expect(result.first.comments.first).to be_a(Automation::Providers::Data::ReviewThreadComment)
      expect(result.first.comments.first.author_login).to eq("alice")
    end
  end

  describe "#fetch_review_requests / #fetch_pending_reviewers" do
    it "returns a Data::ReviewRequest" do
      expect(client).to receive(:pull_request_review_requests)
        .with("acme/widgets", 42)
        .and_return({ users: [ "Alice", "Bob" ], teams: [ "backend" ] })

      result = adapter.fetch_review_requests(repo: "acme/widgets", pr_number: 42)

      expect(result).to be_a(Automation::Providers::Data::ReviewRequest)
      expect(result.users).to eq([ "alice", "bob" ])
      expect(result.teams).to eq([ "backend" ])
    end

    it "exposes pending users as downcased logins" do
      expect(client).to receive(:pull_request_review_requests)
        .and_return({ users: [ "Alice" ], teams: [] })

      expect(adapter.fetch_pending_reviewers(repo: "acme/widgets", pr_number: 42))
        .to eq([ "alice" ])
    end
  end

  describe "#request_reviewers" do
    it "filters out already-pending reviewers and returns the new set" do
      allow(client).to receive(:pull_request_review_requests)
        .and_return({ users: [ "alice" ], teams: [] })
      expect(client).to receive(:request_pull_request_review)
        .with("acme/widgets", 42, reviewers: [ "bob" ])

      result = adapter.request_reviewers(
        repo: "acme/widgets", pr_number: 42, reviewers: [ "Alice", "Bob" ]
      )

      expect(result).to eq([ "bob" ])
    end

    it "is idempotent when everyone requested is already pending" do
      allow(client).to receive(:pull_request_review_requests)
        .and_return({ users: [ "alice" ], teams: [] })
      expect(client).not_to receive(:request_pull_request_review)

      expect(
        adapter.request_reviewers(repo: "acme/widgets", pr_number: 42, reviewers: [ "alice" ])
      ).to eq([])
    end

    it "returns [] for empty inputs without calling the client" do
      expect(client).not_to receive(:pull_request_review_requests)

      expect(adapter.request_reviewers(repo: "acme/widgets", pr_number: 42, reviewers: []))
        .to eq([])
    end
  end

  describe "#submit_review" do
    it "maps the event symbol to GitHub's enum and returns Data::Review" do
      expect(client).to receive(:create_pull_request_review)
        .with("acme/widgets", 42, event: "APPROVE", body: "nice")
        .and_return(OpenStruct.new(
          id: 7, body: "nice", state: "APPROVED",
          submitted_at: Time.utc(2026, 1, 1), commit_id: "def",
          user: OpenStruct.new(login: "Bot")
        ))

      result = adapter.submit_review(
        repo: "acme/widgets", pr_number: 42, body: "nice", event: :approve
      )

      expect(result).to be_a(Automation::Providers::Data::Review)
      expect(result.state).to eq(:approved)
      expect(result.commit_sha).to eq("def")
    end

    it "rejects unknown events" do
      expect {
        adapter.submit_review(repo: "acme/widgets", pr_number: 42, body: "", event: :bogus)
      }.to raise_error(Automation::Providers::ReviewProvider::ProviderError, /Unsupported/)
    end
  end

  describe "#resolve_review_thread" do
    it "forwards the opaque thread id to the GraphQL mutation" do
      expect(client).to receive(:resolve_review_thread).with("thread-node-id")

      expect(
        adapter.resolve_review_thread(repo: "acme/widgets", pr_number: 42, thread_id: "thread-node-id")
      ).to be_nil
    end

    it "translates GithubClient errors into ReviewProvider::ProviderError" do
      expect(client).to receive(:resolve_review_thread)
        .and_raise(GithubClient::ApiError.new("boom", status: 500))

      expect {
        adapter.resolve_review_thread(repo: "acme/widgets", pr_number: 42, thread_id: "t")
      }.to raise_error(Automation::Providers::ReviewProvider::ProviderError)
    end
  end
end
