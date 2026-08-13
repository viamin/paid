# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetPullRequestDetails do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:pr) { create(:issue, :pull_request, project: project) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(
      recent_issue_comments: [],
      pull_request_review_comments: []
    )
  end

  describe "#call" do
    it "returns PR details with serialized comments" do
      comment = Struct.new(:user, :body, :created_at).new(
        Struct.new(:login).new("octocat"),
        "Conversation comment",
        Time.current
      )
      review_comment = {
        user_login: "reviewer",
        body: "Line comment",
        path: "app/models/user.rb",
        created_at: Time.current
      }
      allow(github_client).to receive_messages(
        recent_issue_comments: [ comment ],
        pull_request_review_comments: [ review_comment ]
      )

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(github_client).to have_received(:recent_issue_comments).with(project.full_name, pr.github_number)
      expect(github_client).to have_received(:pull_request_review_comments).with(project.full_name, pr.github_number, per_page: 20)
      expect(result[:comments]).to eq([ { user: "octocat", body: "Conversation comment", created_at: comment.created_at } ])
      expect(result[:review_comments]).to eq([ { user: "reviewer", body: "Line comment", path: "app/models/user.rb", created_at: review_comment[:created_at] } ])
    end

    it "returns empty comment arrays when GitHub calls fail" do
      allow(github_client).to receive(:recent_issue_comments).and_raise(StandardError, "API error")
      allow(github_client).to receive(:pull_request_review_comments).and_raise(StandardError, "API error")

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:comments]).to eq([])
      expect(result[:review_comments]).to eq([])
    end

    it "raises for pull requests outside the user's account" do
      other_pr = create(:issue, :pull_request)

      expect { tool.call(project_id: other_pr.project_id, issue_id: other_pr.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
