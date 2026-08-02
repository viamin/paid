# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SetLabels do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:labels).and_return([
      Struct.new(:name).new("bug"),
      Struct.new(:name).new("enhancement"),
      Struct.new(:name).new("documentation")
    ])
    allow(github_client).to receive(:add_labels_to_issue)
    allow(github_client).to receive(:remove_label_from_issue)
  end

  describe "#call" do
    context "when setting labels on an issue with no existing labels" do
      before do
        bare_issue = Struct.new(:number, :labels).new(42, [])
        allow(github_client).to receive(:issue).and_return(bare_issue)
      end

      it "adds all requested labels" do
        result = tool.call(project_id: project.id, issue_number: 42,
                           labels: %w[bug enhancement])

        expect(github_client).to have_received(:add_labels_to_issue).with(
          project.full_name, 42, %w[bug enhancement]
        )
        expect(result[:added]).to match_array(%w[bug enhancement])
        expect(result[:removed]).to be_empty
        expect(result[:current_labels]).to match_array(%w[bug enhancement])
      end
    end

    context "when replacing labels on an issue with existing labels" do
      before do
        labeled_issue = Struct.new(:number, :labels).new(42, [
          Struct.new(:name).new("bug"),
          Struct.new(:name).new("documentation")
        ])
        allow(github_client).to receive(:issue).and_return(labeled_issue)
      end

      it "adds new labels and removes unwanted ones" do
        result = tool.call(project_id: project.id, issue_number: 42,
                           labels: %w[bug enhancement])

        expect(github_client).to have_received(:add_labels_to_issue).with(
          project.full_name, 42, %w[enhancement]
        )
        expect(github_client).to have_received(:remove_label_from_issue).with(
          project.full_name, 42, "documentation"
        )
        expect(result[:added]).to match_array(%w[enhancement])
        expect(result[:removed]).to match_array(%w[documentation])
        expect(result[:current_labels]).to match_array(%w[bug enhancement])
      end
    end

    context "when labels are already correct" do
      before do
        labeled_issue = Struct.new(:number, :labels).new(42, [
          Struct.new(:name).new("bug"),
          Struct.new(:name).new("enhancement")
        ])
        allow(github_client).to receive(:issue).and_return(labeled_issue)
      end

      it "makes no API calls for add or remove" do
        result = tool.call(project_id: project.id, issue_number: 42,
                           labels: %w[bug enhancement])

        expect(github_client).not_to have_received(:add_labels_to_issue)
        expect(github_client).not_to have_received(:remove_label_from_issue)
        expect(result[:added]).to be_empty
        expect(result[:removed]).to be_empty
      end
    end

    it "rejects unknown labels" do
      expect do
        tool.call(project_id: project.id, issue_number: 42, labels: %w[nonexistent])
      end.to raise_error(ArgumentError, /Unknown labels: nonexistent/)
    end

    it "records an audit event" do
      labeled_issue = Struct.new(:number, :labels).new(42, [
        Struct.new(:name).new("bug")
      ])
      allow(github_client).to receive(:issue).and_return(labeled_issue)

      expect do
        tool.call(project_id: project.id, issue_number: 42, labels: %w[enhancement])
      end.to change(AccountActivityEvent, :count).by(1)

      event = AccountActivityEvent.last
      expect(event.action).to eq("issue.labels_changed")
      expect(event.actor).to eq(user)
      expect(event.subject).to eq(project)
      expect(event.metadata["issue_number"]).to eq(42)
      expect(event.metadata["added"]).to match_array(%w[enhancement])
      expect(event.metadata["removed"]).to match_array(%w[bug])
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect do
        tool.call(project_id: other_project.id, issue_number: 42, labels: %w[bug])
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises for user from another account" do
      other_account = create(:account)
      other_user = create(:user, :member, account: other_account)
      other_tool = described_class.new(user: other_user, session:)

      expect do
        other_tool.call(project_id: project.id, issue_number: 42, labels: %w[bug])
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises on GitHub API failure when fetching current issue" do
      allow(github_client).to receive(:issue).and_raise(GithubClient::Error, "API error")

      expect do
        tool.call(project_id: project.id, issue_number: 42, labels: %w[bug])
      end.to raise_error(GithubClient::Error, "API error")
    end
  end
end
