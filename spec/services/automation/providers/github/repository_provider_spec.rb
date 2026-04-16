# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Automation::Providers::Github::RepositoryProvider do
  # Real stand-ins for Project/GithubToken avoid coupling to the DB schema
  # while still satisfying rubocop's RSpec/VerifiedDoubles rule.
  let(:project_class) do
    Class.new do
      attr_accessor :github_token
      def full_name = "acme/widgets"
    end
  end
  let(:token_class) do
    Class.new do
      attr_accessor :client
      def initialize(client) = (@client = client)
    end
  end

  let(:client) { instance_double(GithubClient) }
  let(:project) { project_class.new }
  let(:adapter) { described_class.new(project, client: client) }

  let(:pr_resource) do
    OpenStruct.new(
      number: 42,
      title: "Add widgets",
      body: "desc",
      state: "open",
      draft: false,
      merged: false,
      mergeable: true,
      merged_at: nil,
      created_at: Time.utc(2026, 1, 1),
      updated_at: Time.utc(2026, 1, 2),
      html_url: "https://github.com/acme/widgets/pull/42",
      head: OpenStruct.new(ref: "feature", sha: "abc123"),
      base: OpenStruct.new(ref: "main"),
      user: OpenStruct.new(login: "Alice"),
      labels: [ OpenStruct.new(name: "automation") ]
    )
  end

  it "conforms to the RepositoryProvider interface" do
    expect(described_class.ancestors).to include(Automation::Providers::RepositoryProvider)
  end

  describe "#fetch_pull_request" do
    it "normalizes Octokit responses to Data::PullRequest" do
      expect(client).to receive(:pull_request).with("acme/widgets", 42).and_return(pr_resource)

      result = adapter.fetch_pull_request(repo: "acme/widgets", number: 42)

      expect(result).to be_a(Automation::Providers::Data::PullRequest)
      expect(result.number).to eq(42)
      expect(result.state).to eq(:open)
      expect(result.head_sha).to eq("abc123")
      expect(result.head_ref).to eq("feature")
      expect(result.base_ref).to eq("main")
      expect(result.author_login).to eq("alice")
      expect(result.labels).to eq([ "automation" ])
      expect(result.raw_state).to eq("open")
    end

    it "translates GithubClient errors into ProviderError" do
      expect(client).to receive(:pull_request).and_raise(GithubClient::NotFoundError)

      expect {
        adapter.fetch_pull_request(repo: "acme/widgets", number: 99)
      }.to raise_error(Automation::Providers::RepositoryProvider::ProviderError)
    end

    it "derives merged from merged_at when #merged is false" do
      pr_resource.state = "closed"
      pr_resource.merged_at = Time.utc(2026, 2, 1)
      allow(client).to receive(:pull_request).and_return(pr_resource)

      result = adapter.fetch_pull_request(repo: "acme/widgets", number: 42)

      expect(result.state).to eq(:closed)
      expect(result.merged).to be true
      expect(result.merged_at).to eq(Time.utc(2026, 2, 1))
    end
  end

  describe "#list_pull_requests" do
    it "forwards filter options to the client" do
      expect(client).to receive(:pull_requests)
        .with("acme/widgets", state: "open", head: "acme:feature", base: "main")
        .and_return([ pr_resource ])

      result = adapter.list_pull_requests(
        repo: "acme/widgets", state: :open, head: "acme:feature", base: "main"
      )

      expect(result.size).to eq(1)
      expect(result.first).to be_a(Automation::Providers::Data::PullRequest)
    end

    it "omits nil head/base options" do
      expect(client).to receive(:pull_requests)
        .with("acme/widgets", state: "all")
        .and_return([])

      adapter.list_pull_requests(repo: "acme/widgets", state: :all)
    end
  end

  describe "#fetch_pull_request_files" do
    it "returns the string list the client provides" do
      expect(client).to receive(:pull_request_files)
        .with("acme/widgets", 42)
        .and_return([ "a.rb", "b.rb" ])

      expect(adapter.fetch_pull_request_files(repo: "acme/widgets", number: 42))
        .to eq([ "a.rb", "b.rb" ])
    end
  end

  describe "#fetch_check_runs" do
    let(:completed_run) do
      {
        name: "test",
        status: "completed",
        conclusion: "success",
        html_url: "https://github.com/acme/widgets/runs/1",
        details_url: "https://ci.example.com/jobs/1"
      }
    end
    let(:in_progress_run) do
      {
        name: "integration",
        status: "in_progress",
        conclusion: nil,
        html_url: nil,
        details_url: "https://ci.example.com/jobs/2"
      }
    end
    let(:queued_run) do
      { name: "lint", status: "queued", conclusion: nil, html_url: nil, details_url: nil }
    end

    before do
      allow(client).to receive(:check_runs_for_ref)
        .with("acme/widgets", "abc123")
        .and_return([ completed_run, in_progress_run, queued_run ])
    end

    it "normalizes completed runs with their conclusion and URL" do
      run = adapter.fetch_check_runs(repo: "acme/widgets", ref: "abc123").first

      expect(run).to be_a(Automation::Providers::Data::CheckRun)
      expect(run).to have_attributes(
        name: "test",
        status: :completed,
        conclusion: :success,
        url: "https://github.com/acme/widgets/runs/1"
      )
    end

    # Critical regression guard: an in-progress check must not be reported
    # as :completed. That would let consumers gating on execution progress
    # (e.g. "all checks finished?") advance while work is still running.
    it "reports in-progress runs as :in_progress, not :completed" do
      run = adapter.fetch_check_runs(repo: "acme/widgets", ref: "abc123")[1]

      expect(run).to have_attributes(
        status: :in_progress,
        conclusion: nil,
        url: "https://ci.example.com/jobs/2"
      )
    end

    it "reports queued runs as :queued with no URL when neither html_url nor details_url is present" do
      run = adapter.fetch_check_runs(repo: "acme/widgets", ref: "abc123").last

      expect(run).to have_attributes(status: :queued, conclusion: nil, url: nil)
    end
  end

  describe "#add_labels" do
    it "adds non-empty labels to the issue" do
      expect(client).to receive(:add_labels_to_issue)
        .with("acme/widgets", 42, [ "automation", "ready" ])

      adapter.add_labels(repo: "acme/widgets", number: 42, labels: [ "automation", "ready", "" ])
    end

    it "no-ops when labels is empty" do
      expect(client).not_to receive(:add_labels_to_issue)
      adapter.add_labels(repo: "acme/widgets", number: 42, labels: [])
    end
  end

  describe "#remove_label" do
    it "calls the client and returns nil on success" do
      expect(client).to receive(:remove_label_from_issue)
        .with("acme/widgets", 42, "stale")

      expect(adapter.remove_label(repo: "acme/widgets", number: 42, label: "stale")).to be_nil
    end

    it "swallows 404 as idempotent" do
      expect(client).to receive(:remove_label_from_issue)
        .and_raise(GithubClient::NotFoundError, "not found")

      expect {
        adapter.remove_label(repo: "acme/widgets", number: 42, label: "stale")
      }.not_to raise_error
    end

    it "swallows 404 regardless of the underlying message text" do
      # Octokit does not guarantee "not found" appears in every 404 body
      # (e.g. "Label does not exist"). Classification must be by error
      # class, not message regex.
      expect(client).to receive(:remove_label_from_issue)
        .and_raise(GithubClient::NotFoundError, "Label does not exist")

      expect {
        adapter.remove_label(repo: "acme/widgets", number: 42, label: "stale")
      }.not_to raise_error
    end

    it "propagates unexpected provider errors" do
      expect(client).to receive(:remove_label_from_issue)
        .and_raise(GithubClient::ApiError.new("boom", status: 500))

      expect {
        adapter.remove_label(repo: "acme/widgets", number: 42, label: "stale")
      }.to raise_error(Automation::Providers::RepositoryProvider::ProviderError)
    end
  end

  describe "#add_comment" do
    it "returns the created comment as Data::Comment" do
      created = OpenStruct.new(
        id: 99,
        body: "hi",
        created_at: Time.utc(2026, 3, 1),
        updated_at: Time.utc(2026, 3, 1),
        html_url: "https://github.com/acme/widgets/pull/42#c99",
        user: OpenStruct.new(login: "Bot")
      )
      expect(client).to receive(:add_comment)
        .with("acme/widgets", 42, "hi")
        .and_return(created)

      result = adapter.add_comment(repo: "acme/widgets", number: 42, body: "hi")

      expect(result).to be_a(Automation::Providers::Data::Comment)
      expect(result.id).to eq(99)
      expect(result.author_login).to eq("bot")
      expect(result.body).to eq("hi")
    end
  end

  describe "#mark_ready_for_review" do
    it "delegates to the GraphQL helper" do
      expect(client).to receive(:mark_pull_request_ready).with("acme/widgets", 42)

      expect(adapter.mark_ready_for_review(repo: "acme/widgets", number: 42)).to be_nil
    end
  end

  describe "#merge_pull_request" do
    it "forwards the merge method and returns a normalized MergeResult" do
      expect(client).to receive(:merge_pull_request).with(
        "acme/widgets",
        42,
        merge_method: "squash",
        commit_title: "Title",
        commit_message: "Body"
      ).and_return(OpenStruct.new(merged: true, sha: "def456", message: "Squashed"))

      result = adapter.merge_pull_request(
        repo: "acme/widgets", number: 42, method: :squash,
        commit_title: "Title", commit_message: "Body"
      )

      expect(result).to be_a(Automation::Providers::Data::MergeResult)
      expect(result.merged).to be true
      expect(result.sha).to eq("def456")
    end

    it "rejects unsupported merge methods" do
      expect {
        adapter.merge_pull_request(repo: "acme/widgets", number: 42, method: :fast_forward)
      }.to raise_error(Automation::Providers::RepositoryProvider::ProviderError, /Unsupported/)
    end

    it "defaults merged to false when the response omits the field" do
      # Guard against a malformed response (or an incomplete test mock)
      # reporting a successful merge by accident. Only a literal
      # +merged: true+ should produce +merged: true+ in the result.
      expect(client).to receive(:merge_pull_request).and_return(OpenStruct.new(sha: "abc"))

      result = adapter.merge_pull_request(repo: "acme/widgets", number: 42, method: :squash)

      expect(result.merged).to be false
    end
  end

  describe "client resolution" do
    it "derives the client from the project's github_token when not injected" do
      project.github_token = token_class.new(client)
      resolved = described_class.new(project)

      expect(resolved.client).to eq(client)
    end

    it "raises when no GitHub token is configured" do
      project.github_token = nil
      resolved = described_class.new(project)

      expect { resolved.client }.to raise_error(
        Automation::Providers::RepositoryProvider::ProviderError, /no GitHub token/
      )
    end
  end
end
