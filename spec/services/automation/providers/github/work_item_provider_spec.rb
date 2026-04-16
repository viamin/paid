# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Automation::Providers::Github::WorkItemProvider do
  let(:project_class) do
    Class.new do
      def full_name = "acme/widgets"
    end
  end

  let(:client) { instance_double(GithubClient) }
  let(:project) { project_class.new }
  let(:adapter) { described_class.new(project, client: client) }

  let(:issue_resource) do
    OpenStruct.new(
      number: 42,
      title: "Bug",
      body: "details",
      state: "open",
      created_at: Time.utc(2026, 1, 1),
      updated_at: Time.utc(2026, 1, 2),
      closed_at: nil,
      html_url: "https://github.com/acme/widgets/issues/42",
      user: OpenStruct.new(login: "Alice"),
      assignees: [ OpenStruct.new(login: "Bob") ],
      labels: [ OpenStruct.new(name: "bug"), OpenStruct.new(name: "priority:high") ],
      pull_request: nil
    )
  end

  it "conforms to the WorkItemProvider interface" do
    expect(described_class.ancestors).to include(Automation::Providers::WorkItemProvider)
  end

  describe "#fetch_issue" do
    it "normalizes the issue response" do
      expect(client).to receive(:issue).with("acme/widgets", 42).and_return(issue_resource)

      result = adapter.fetch_issue(repo: "acme/widgets", number: 42)

      expect(result).to be_a(Automation::Providers::Data::Issue)
      expect(result.number).to eq(42)
      expect(result.state).to eq(:open)
      expect(result.labels).to eq([ "bug", "priority:high" ])
      expect(result.assignee_logins).to eq([ "bob" ])
      expect(result.author_login).to eq("alice")
      expect(result.dependencies).to eq([])
      expect(result.pull_request_number).to be_nil
    end

    it "exposes pull_request_number when the item is also a PR" do
      issue_resource.pull_request = OpenStruct.new(url: "...")

      expect(client).to receive(:issue).and_return(issue_resource)

      result = adapter.fetch_issue(repo: "acme/widgets", number: 42)

      expect(result.pull_request_number).to eq(42)
    end

    it "translates GithubClient errors to WorkItemProvider::ProviderError" do
      expect(client).to receive(:issue).and_raise(GithubClient::AuthenticationError)

      expect {
        adapter.fetch_issue(repo: "acme/widgets", number: 1)
      }.to raise_error(Automation::Providers::WorkItemProvider::ProviderError)
    end
  end

  describe "#list_issues" do
    it "forwards state and label filters" do
      expect(client).to receive(:issues)
        .with("acme/widgets", labels: [ "bug" ], state: "open")
        .and_return([ issue_resource ])

      result = adapter.list_issues(repo: "acme/widgets", state: :open, labels: [ "bug" ])

      expect(result.size).to eq(1)
      expect(result.first.number).to eq(42)
    end

    it "passes the first assignee to the client when provided" do
      expect(client).to receive(:issues)
        .with("acme/widgets", labels: nil, state: "open", assignee: "bob")
        .and_return([])

      adapter.list_issues(repo: "acme/widgets", assignees: [ "bob" ])
    end
  end

  describe "#fetch_issue_comments" do
    it "normalizes comments" do
      raw = OpenStruct.new(
        id: 7,
        body: "hi",
        created_at: Time.utc(2026, 1, 1),
        updated_at: Time.utc(2026, 1, 1),
        html_url: "http://example.com/7",
        user: OpenStruct.new(login: "Carol")
      )
      expect(client).to receive(:issue_comments).with("acme/widgets", 42).and_return([ raw ])

      result = adapter.fetch_issue_comments(repo: "acme/widgets", number: 42)

      expect(result.first).to be_a(Automation::Providers::Data::Comment)
      expect(result.first.author_login).to eq("carol")
    end
  end

  describe "#fetch_issue_timeline" do
    it "maps known events to the canonical set" do
      event = {
        event: "labeled",
        created_at: Time.utc(2026, 1, 1),
        actor: { login: "Dave" },
        label: { name: "bug" }
      }
      expect(client).to receive(:issue_events).with("acme/widgets", 42).and_return([ event ])

      result = adapter.fetch_issue_timeline(repo: "acme/widgets", number: 42)

      expect(result.first).to be_a(Automation::Providers::Data::TimelineEvent)
      expect(result.first.event).to eq(:labeled)
      expect(result.first.label_name).to eq("bug")
      expect(result.first.actor_login).to eq("dave")
    end

    it "falls back to :other for unknown events" do
      event = { event: "transferred", created_at: Time.utc(2026, 1, 1), actor: { login: "Dave" } }
      expect(client).to receive(:issue_events).and_return([ event ])

      result = adapter.fetch_issue_timeline(repo: "acme/widgets", number: 42)

      expect(result.first.event).to eq(:other)
    end
  end

  describe "#create_issue" do
    it "delegates to the client with normalized labels" do
      expect(client).to receive(:create_issue)
        .with("acme/widgets", title: "New", body: "body", labels: [ "a" ])
        .and_return(issue_resource)

      result = adapter.create_issue(repo: "acme/widgets", title: "New", body: "body", labels: [ "a", "" ])

      expect(result).to be_a(Automation::Providers::Data::Issue)
    end
  end

  describe "#add_labels / #remove_label / #add_comment" do
    it "#add_labels forwards labels" do
      expect(client).to receive(:add_labels_to_issue).with("acme/widgets", 42, [ "bug" ])
      adapter.add_labels(repo: "acme/widgets", number: 42, labels: [ "bug" ])
    end

    it "#remove_label is idempotent for 404" do
      expect(client).to receive(:remove_label_from_issue).and_raise(GithubClient::NotFoundError)

      expect {
        adapter.remove_label(repo: "acme/widgets", number: 42, label: "stale")
      }.not_to raise_error
    end

    it "#remove_label swallows 404 regardless of the underlying message text" do
      # Octokit does not guarantee "not found" appears in every 404 body
      # (e.g. "Label does not exist"). Classification must be by error
      # class, not message regex.
      expect(client).to receive(:remove_label_from_issue)
        .and_raise(GithubClient::NotFoundError, "Label does not exist")

      expect {
        adapter.remove_label(repo: "acme/widgets", number: 42, label: "stale")
      }.not_to raise_error
    end

    it "#add_comment returns a Data::Comment" do
      created = OpenStruct.new(
        id: 3, body: "hey",
        created_at: Time.utc(2026, 1, 1), updated_at: nil, html_url: nil,
        user: OpenStruct.new(login: "Bot")
      )
      expect(client).to receive(:add_comment).with("acme/widgets", 42, "hey").and_return(created)

      result = adapter.add_comment(repo: "acme/widgets", number: 42, body: "hey")

      expect(result.author_login).to eq("bot")
    end
  end

  describe "#transition_state" do
    it "updates the issue state through the client" do
      expect(client).to receive(:update_issue)
        .with("acme/widgets", 42, state: "closed", state_reason: "completed")
        .and_return(issue_resource)

      result = adapter.transition_state(
        repo: "acme/widgets", number: 42, state: :closed, reason: "completed"
      )

      expect(result).to be_a(Automation::Providers::Data::Issue)
    end

    it "rejects states that are not part of the canonical set" do
      expect {
        adapter.transition_state(repo: "acme/widgets", number: 42, state: :in_progress)
      }.to raise_error(Automation::Providers::WorkItemProvider::ProviderError, /Unsupported/)
    end
  end
end
