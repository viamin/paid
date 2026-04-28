# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetIssueDetails do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe "#call" do
    let(:project) { create(:project, account: account) }
    let(:issue) { create(:issue, project: project) }
    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(GithubClient).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:issue_comments).and_return([])
    end

    it "returns issue details" do
      result = tool.call(project_id: project.id, issue_id: issue.id)

      expect(result[:id]).to eq(issue.id)
      expect(result[:title]).to eq(issue.title)
      expect(result[:github_number]).to eq(issue.github_number)
      expect(result).to have_key(:body)
      expect(result).to have_key(:labels)
      expect(result).to have_key(:comments)
    end

    it "includes comments from GitHub" do
      comment = Struct.new(:user, :body, :created_at).new(
        Struct.new(:login).new("octocat"),
        "A comment",
        Time.current
      )
      allow(github_client).to receive(:issue_comments).and_return([ comment ])

      result = tool.call(project_id: project.id, issue_id: issue.id)

      expect(result[:comments].size).to eq(1)
      expect(result[:comments].first[:user]).to eq("octocat")
      expect(result[:comments].first[:body]).to eq("A comment")
    end

    it "returns empty comments when GitHub API fails" do
      allow(github_client).to receive(:issue_comments).and_raise(StandardError, "API error")

      result = tool.call(project_id: project.id, issue_id: issue.id)

      expect(result[:comments]).to eq([])
    end

    it "raises for project in another account" do
      other_project = create(:project)
      other_issue = create(:issue, project: other_project)

      expect { tool.call(project_id: other_project.id, issue_id: other_issue.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
