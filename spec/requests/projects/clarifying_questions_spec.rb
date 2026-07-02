# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::ClarifyingQuestions" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }
  let(:issue_body) { "This is the issue body" }
  let(:issue) { create(:issue, :needs_input, project: project, body: issue_body) }
  let(:github_client) { instance_double(GithubClient) }
  let(:comment_body) do
    <<~COMMENT
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
      2. Should this be behind a flag?

      ## Current context
      - Some context
    COMMENT
  end
  let(:trusted_comment) { double(body: comment_body, user: double(login: "viamin")) }

  before do
    sign_in user
    user.add_role(:admin, account)
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "GET /projects/:project_id/issues/:issue_id/clarifying_questions" do
    context "when enhancement comment with clarifying questions exists" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([ trusted_comment ])
      end

      it "renders the wizard view" do
        get project_issue_clarifying_questions_path(project, issue)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Clarifying Questions")
        expect(response.body).to include("What is the expected behavior?")
        expect(response.body).to include("Should this be behind a flag?")
        expect(response.body).to include('submit-&gt;clarifying-questions#submit')
        expect(response.body).to include('disabled="disabled"')
      end

      it "includes the issue id in the chat popup context" do
        get project_issue_clarifying_questions_path(project, issue)

        popup = Nokogiri::HTML(response.body).at_css('[data-controller="chat-popup"]')
        context = JSON.parse(popup["data-chat-popup-context-value"])

        expect(context).to include(
          "project_id" => project.id,
          "issue_id" => issue.id
        )
      end
    end

    context "when no clarifying questions found" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([])
      end

      it "redirects to project page with alert" do
        get project_issue_clarifying_questions_path(project, issue)

        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("No clarifying questions found")
      end
    end
  end

  describe "POST /projects/:project_id/issues/:issue_id/clarifying_questions" do
    before do
      allow(github_client).to receive(:add_comment).and_return(double(html_url: "https://github.com/test"))
      allow(github_client).to receive(:remove_label_from_issue)
    end

    context "when all answers are provided" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([ trusted_comment ])
      end

      it "posts answers as a GitHub comment and redirects" do
        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: [ "What is the expected behavior?", "Should this be behind a flag?" ],
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

      it "clears the needs-input marker so the Answer Questions button disappears" do
        needs_input_label = project.enhance_issue_needs_input_label_name

        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: [ "What is the expected behavior?", "Should this be behind a flag?" ],
          answers: [ "X is a feature", "Yes, by default" ]
        }

        expect(github_client).to have_received(:remove_label_from_issue).with(
          project.full_name, issue.github_number, needs_input_label
        )
        issue.reload
        expect(issue.paid_state).to eq("new")
        expect(issue.needs_input?).to be false
        expect(issue.labels).not_to include(needs_input_label)
      end
    end

    context "when some answers are blank" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([ trusted_comment ])
      end

      it "redirects back with an alert" do
        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: [ "What is the expected behavior?", "Should this be behind a flag?" ],
          answers: [ "X is a feature", "" ]
        }

        expect(response).to redirect_to(project_issue_clarifying_questions_path(project, issue))
      end
    end

    context "when the submitted questions no longer match the current questions" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([ trusted_comment ])
      end

      it "redirects back with an alert instead of posting mismatched answers" do
        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: [ "Tampered question?" ],
          answers: [ "Tampered answer" ]
        }

        expect(github_client).not_to have_received(:add_comment)
        expect(response).to redirect_to(project_issue_clarifying_questions_path(project, issue))
      end
    end

    context "when the issue no longer has clarifying questions" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([])
      end

      it "redirects back with an alert instead of posting an empty comment" do
        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: [ "Tampered question?" ],
          answers: [ "Tampered answer" ]
        }

        expect(github_client).not_to have_received(:add_comment)
        expect(response).to redirect_to(project_issue_clarifying_questions_path(project, issue))
      end
    end
  end
end
