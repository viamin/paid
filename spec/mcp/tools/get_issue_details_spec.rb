# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetIssueDetails do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe "#call" do
    it "returns issue details" do
      project = create(:project, account: account)
      issue = create(:issue, project: project)

      result = tool.call(project_id: project.id, issue_id: issue.id)

      expect(result[:id]).to eq(issue.id)
      expect(result[:title]).to eq(issue.title)
      expect(result[:github_number]).to eq(issue.github_number)
      expect(result).to have_key(:body)
      expect(result).to have_key(:labels)
    end

    it "raises for project in another account" do
      other_project = create(:project)
      other_issue = create(:issue, project: other_project)

      expect { tool.call(project_id: other_project.id, issue_id: other_issue.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
