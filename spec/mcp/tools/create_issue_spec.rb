# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::CreateIssue do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:) }
  let(:github_client) { instance_double(GithubClient) }
  let(:local_issue) { create(:issue, project:) }
  let(:created_issue) do
    Struct.new(:number, :html_url).new(42, "https://github.com/owner/repo/issues/42")
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(Issues::UpsertFromGithub).to receive(:call).and_return(local_issue)
    allow(Issues::ParseDependencies).to receive(:call)
    allow(github_client).to receive_messages(create_issue: created_issue, labels: [
      Struct.new(:name).new("bug"),
      Struct.new(:name).new("enhancement"),
      Struct.new(:name).new("documentation")
    ])
  end

  describe "#call" do
    it "creates an issue and returns number and url" do
      result = tool.call(project_id: project.id, title: "Test issue", body: "Test body")

      expect(github_client).to have_received(:create_issue).with(
        project.full_name, title: "Test issue", body: "Test body", labels: [], assignees: []
      )
      expect(Issues::UpsertFromGithub).to have_received(:call).with(project:, github_issue: created_issue)
      expect(Issues::ParseDependencies).to have_received(:call).with(issue: local_issue)
      expect(result[:number]).to eq(42)
      expect(result[:url]).to eq("https://github.com/owner/repo/issues/42")
    end

    it "creates an issue with labels" do
      result = tool.call(project_id: project.id, title: "Test issue", labels: %w[bug enhancement])

      expect(github_client).to have_received(:create_issue).with(
        project.full_name, title: "Test issue", body: "", labels: %w[bug enhancement], assignees: []
      )
      expect(result[:number]).to eq(42)
    end

    it "creates an issue with assignees" do
      result = tool.call(project_id: project.id, title: "Test issue", assignees: %w[octocat])

      expect(github_client).to have_received(:create_issue).with(
        project.full_name, title: "Test issue", body: "", labels: [], assignees: %w[octocat]
      )
      expect(result[:number]).to eq(42)
    end

    it "records an audit event" do
      expect do
        tool.call(project_id: project.id, title: "Test issue")
      end.to change(AccountActivityEvent, :count).by(1)

      event = AccountActivityEvent.last
      expect(event.action).to eq("issue.created")
      expect(event.actor).to eq(user)
      expect(event.subject).to eq(project)
      expect(event.metadata["issue_number"]).to eq(42)
    end

    it "rejects unknown labels" do
      expect do
        tool.call(project_id: project.id, title: "Test issue", labels: %w[nonexistent])
      end.to raise_error(ArgumentError, /Unknown labels: nonexistent/)
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect do
        tool.call(project_id: other_project.id, title: "Test issue")
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises for user from another account" do
      other_account = create(:account)
      other_user = create(:user, :member, account: other_account)
      other_tool = described_class.new(user: other_user, session:)

      expect do
        other_tool.call(project_id: project.id, title: "Test issue")
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises on GitHub API failure" do
      allow(github_client).to receive(:create_issue).and_raise(GithubClient::Error, "API error")

      expect do
        tool.call(project_id: project.id, title: "Test issue")
      end.to raise_error(GithubClient::Error, "API error")
    end

    it "propagates label fetch failures" do
      allow(github_client).to receive(:labels).and_raise(GithubClient::Error, "rate limited")

      expect do
        tool.call(project_id: project.id, title: "Test issue", labels: %w[bug])
      end.to raise_error(GithubClient::Error, "rate limited")
    end

    context "with dependency in body" do
      let(:created_issue) do
        user_struct = Struct.new(:login).new("test-user")
        label_struct = Struct.new(:name)
        Struct.new(:id, :number, :html_url, :title, :body, :user, :state, :labels, :created_at, :updated_at).new(
          12_345, 42, "https://github.com/owner/repo/issues/42",
          "Test issue", "Depends on viamin/foo#42",
          user_struct, "open",
          [ label_struct.new("bug") ],
          Time.current, Time.current
        )
      end

      before do
        allow(Issues::UpsertFromGithub).to receive(:call).and_call_original
        allow(Issues::ParseDependencies).to receive(:call).and_call_original
      end

      it "parses dependencies from the issue body and persists them" do
        result = tool.call(
          project_id: project.id,
          title: "Test issue",
          body: "Depends on viamin/foo#42"
        )

        expect(result[:number]).to eq(42)

        local = Issue.find_by(github_issue_id: 12_345, project:)
        expect(local).to be_present
        expect(local.body).to include("Depends on viamin/foo#42")
        expect(local.issue_dependencies.count).to eq(1)
        dep = local.issue_dependencies.first
        expect(dep).to be_external
        expect(dep.external_ref).to eq("viamin/foo#42")
      end
    end

    context "with GitHub App installation" do
      let(:project) { create(:project, :with_github_installation, account:) }

      before do
        allow(Github::AppInstallation).to receive(:token_for).and_return("ghs_installation_token")
      end

      it "creates an issue using the installation credential" do
        result = tool.call(project_id: project.id, title: "Test issue")

        expect(github_client).to have_received(:create_issue).with(
          project.full_name, title: "Test issue", body: "", labels: [], assignees: []
        )
        expect(result[:number]).to eq(42)
      end
    end
  end
end
