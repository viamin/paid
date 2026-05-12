# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::ClarifyingQuestions" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, :needs_input, project: project) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    sign_in user
    user.add_role(:admin, account)
    allow(project.github_token).to receive(:client).and_return(github_client)
  end

  describe "GET /projects/:project_id/issues/:issue_id/clarifying_questions" do
    context "when enhancement comment with clarifying questions exists" do
      before do
        comment_body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What is the expected behavior?
          2. Should this be behind a flag?

          ## Current context
          - Some context
        COMMENT

        comment = double(body: comment_body)
        allow(github_client).to receive(:issue_comments).and_return([ comment ])
      end

      it "renders the wizard view" do
        get project_issue_clarifying_question_path(project, issue)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Clarifying Questions")
        expect(response.body).to include("What is the expected behavior?")
        expect(response.body).to include("Should this be behind a flag?")
        expect(response.body).to include('submit-&gt;clarifying-questions#submit')
        expect(response.body).to include('disabled="disabled"')
      end
    end

    context "when no clarifying questions found" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([])
      end

      it "redirects to project page with alert" do
        get project_issue_clarifying_question_path(project, issue)

        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("No clarifying questions found")
      end
    end
  end

  describe "POST /projects/:project_id/issues/:issue_id/clarifying_questions" do
    before do
      allow(github_client).to receive(:add_comment).and_return(double(html_url: "https://github.com/test"))
    end

    context "when all answers are provided" do
      it "posts answers as a GitHub comment and redirects" do
        post project_issue_clarifying_question_path(project, issue), params: {
          questions: [ "What is X?", "Should this be enabled?" ],
          answers: [ "X is a feature", "Yes, by default" ]
        }

        expect(github_client).to have_received(:add_comment).with(
          project.full_name,
          issue.github_number,
          a_string_matching(/Clarifying question answers/)
        )
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Answers posted to GitHub issue")
      end
    end

    context "when some answers are blank" do
      it "redirects back with an alert" do
        post project_issue_clarifying_question_path(project, issue), params: {
          questions: [ "What is X?", "Should this be enabled?" ],
          answers: [ "X is a feature", "" ]
        }

        expect(response).to redirect_to(project_issue_clarifying_question_path(project, issue))
      end
    end

    context "when the issue no longer has clarifying questions" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([])
      end

      it "redirects back with an alert instead of posting an empty comment" do
        post project_issue_clarifying_question_path(project, issue), params: {
          questions: [ "Tampered question?" ],
          answers: [ "Tampered answer" ]
        }

        expect(github_client).not_to have_received(:add_comment)
        expect(response).to redirect_to(project_issue_clarifying_question_path(project, issue))
      end
    end
  end
end
