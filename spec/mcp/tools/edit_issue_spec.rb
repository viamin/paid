# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::EditIssue do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:) }
  let(:github_client) { instance_double(GithubClient) }
  let(:updated_issue) do
    Struct.new(:number, :html_url, :title, :state).new(
      42, "https://github.com/owner/repo/issues/42", "Updated title", "open"
    )
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(update_issue: updated_issue, labels: [
      Struct.new(:name).new("bug"),
      Struct.new(:name).new("enhancement")
    ])
  end

  describe "#call" do
    it "updates the issue title" do
      result = tool.call(project_id: project.id, issue_number: 42, title: "Updated title")

      expect(github_client).to have_received(:update_issue).with(project.full_name, 42, title: "Updated title")
      expect(result[:title]).to eq("Updated title")
    end

    it "updates the issue body" do
      tool.call(project_id: project.id, issue_number: 42, body: "New body")

      expect(github_client).to have_received(:update_issue).with(project.full_name, 42, body: "New body")
    end

    it "updates the issue state" do
      tool.call(project_id: project.id, issue_number: 42, state: "closed")

      expect(github_client).to have_received(:update_issue).with(project.full_name, 42, state: "closed")
    end

    it "updates multiple fields at once" do
      tool.call(project_id: project.id, issue_number: 42, title: "X", body: "Y", state: "closed")

      expect(github_client).to have_received(:update_issue).with(
        project.full_name, 42, title: "X", body: "Y", state: "closed"
      )
    end

    it "validates labels when present" do
      tool.call(project_id: project.id, issue_number: 42, labels: %w[bug])

      expect(github_client).to have_received(:update_issue).with(project.full_name, 42, labels: %w[bug])
    end

    it "rejects unknown labels" do
      expect do
        tool.call(project_id: project.id, issue_number: 42, labels: %w[nonexistent])
      end.to raise_error(ArgumentError, /Unknown labels: nonexistent/)
    end

    it "raises when no fields are provided" do
      expect do
        tool.call(project_id: project.id, issue_number: 42)
      end.to raise_error(ArgumentError, "No fields to update")
    end

    it "records an audit event" do
      expect do
        tool.call(project_id: project.id, issue_number: 42, title: "Updated title")
      end.to change(AccountActivityEvent, :count).by(1)

      event = AccountActivityEvent.last
      expect(event.action).to eq("issue.updated")
      expect(event.actor).to eq(user)
      expect(event.subject).to eq(project)
      expect(event.metadata["issue_number"]).to eq(42)
      expect(event.metadata["changes"]).to include("title")
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect do
        tool.call(project_id: other_project.id, issue_number: 42, title: "X")
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises for user from another account" do
      other_account = create(:account)
      other_user = create(:user, :member, account: other_account)
      other_tool = described_class.new(user: other_user, session:)

      expect do
        other_tool.call(project_id: project.id, issue_number: 42, title: "X")
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises on GitHub API failure" do
      allow(github_client).to receive(:update_issue).and_raise(GithubClient::Error, "API error")

      expect do
        tool.call(project_id: project.id, issue_number: 42, title: "X")
      end.to raise_error(GithubClient::Error, "API error")
    end
  end
end
