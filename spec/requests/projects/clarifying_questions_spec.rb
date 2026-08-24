# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::ClarifyingQuestions" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
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

  def dashboard_queue_path_for(project)
    dashboard_needs_input_path(project_id: project.id)
  end

  def dashboard_queue_params(project)
    path = dashboard_queue_path_for(project)
    { queue: "dashboard_needs_input", queue_project_id: project.id, return_to: path }
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

    context "when a question contains markdown" do
      let(:markdown_question) { "Should `foo_bar` use **snake_case** or [camelCase](https://example.com)?" }
      let(:comment_body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. #{markdown_question}

          ## Current context
          - Some context
        COMMENT
      end

      before do
        allow(github_client).to receive(:issue_comments).and_return([ trusted_comment ])
      end

      it "wires the raw question text into the markdown-text controller for client-side rendering" do
        get project_issue_clarifying_questions_path(project, issue)

        heading = Nokogiri::HTML(response.body).at_css('[data-controller="markdown-text"]')

        expect(heading["data-markdown-text-content-value"]).to eq(markdown_question)
      end

      it "escapes the fallback text so it never renders as raw HTML before JS runs" do
        get project_issue_clarifying_questions_path(project, issue)

        expect(response.body).to include(CGI.escapeHTML(markdown_question))
        expect(response.body).not_to include("<strong>snake_case</strong>")
      end

      it "keeps the hidden field value equal to the raw, unrendered question text" do
        get project_issue_clarifying_questions_path(project, issue)

        hidden_field = Nokogiri::HTML(response.body).at_css("#question_0")

        expect(hidden_field["value"]).to eq(markdown_question)
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

      it "falls back to the validated dashboard queue path when return_to is unsafe" do
        project.update!(auto_pick_enabled: true, active: true)

        get project_issue_clarifying_questions_path(project, issue), params: {
          queue: "dashboard_needs_input",
          queue_project_id: project.id,
          return_to: "//evil.example/path"
        }

        expect(response).to redirect_to(dashboard_needs_input_path(project_id: project.id))
      end
    end
  end

  describe "POST /projects/:project_id/issues/:issue_id/clarifying_questions" do
    before do
      allow(github_client).to receive(:add_comment).and_return(double(html_url: "https://github.com/test"))
      allow(github_client).to receive(:remove_label_from_issue)
    end

    context "when all answers are provided" do
      let(:questions) { [ "What is the expected behavior?", "Should this be behind a flag?" ] }
      let(:answers) { [ "X is a feature", "Yes, by default" ] }
      let(:issue) do
        create(:issue, :needs_input, project: project, body: issue_body, needs_input_questions: questions)
      end

      before do
        allow(github_client).to receive(:issue_comments).and_return([ trusted_comment ])
      end

      it "posts answers as a GitHub comment and redirects" do
        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: questions,
          answers: answers
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
          questions: questions,
          answers: answers
        }

        expect(github_client).to have_received(:remove_label_from_issue).with(
          project.full_name, issue.github_number, needs_input_label
        )
        issue.reload
        expect(issue.paid_state).to eq("new")
        expect(issue.needs_input?).to be false
        expect(issue.labels).not_to include(needs_input_label)
      end

      it "redirects to the next queued issue when opened from the dashboard queue" do
        project.update!(auto_pick_enabled: true, active: true)
        create(:issue, :needs_input, project: project, github_number: issue.github_number + 1, body: "Needs manual retry")
        next_issue = create(:issue, :needs_input, project: project, github_number: issue.github_number + 2,
          needs_input_questions: [ "What should happen next?" ])
        queue_params = dashboard_queue_params(project)

        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: questions,
          answers: answers,
          **queue_params
        }

        expect(response).to redirect_to(
          project_issue_clarifying_questions_path(
            project,
            next_issue,
            **queue_params
          )
        )
      end

      it "returns to the dashboard queue when the queue is exhausted" do
        project.update!(auto_pick_enabled: true, active: true)
        queue_return_to = dashboard_queue_path_for(project)

        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: questions,
          answers: answers,
          queue: "dashboard_needs_input",
          queue_project_id: project.id,
          return_to: queue_return_to
        }

        expect(response).to redirect_to(queue_return_to)
      end

      it "falls back to the validated dashboard queue path when return_to is unsafe" do
        project.update!(auto_pick_enabled: true, active: true)

        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: questions,
          answers: answers,
          queue: "dashboard_needs_input",
          queue_project_id: project.id,
          return_to: "https://evil.example/path"
        }

        expect(response).to redirect_to(dashboard_needs_input_path(project_id: project.id))
      end

      it "preserves the validated queue return target when posting fails" do
        project.update!(auto_pick_enabled: true, active: true)
        return_to = dashboard_needs_input_path(project_id: project.id)
        allow(github_client).to receive(:add_comment).and_raise(GithubClient::Error, "boom")

        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: questions,
          answers: answers,
          queue: "dashboard_needs_input",
          queue_project_id: project.id,
          return_to: return_to
        }

        expect(response).to redirect_to(
          project_issue_clarifying_questions_path(
            project,
            issue,
            queue: "dashboard_needs_input",
            queue_project_id: project.id,
            return_to: return_to
          )
        )
      end

      it "does not continue into a different queue project scope" do
        project.update!(auto_pick_enabled: true, active: true)
        other_project = create(
          :project,
          account: account,
          created_by: user,
          auto_pick_enabled: true,
          active: true
        )
        create(:issue, :needs_input, project: other_project,
          github_number: issue.github_number + 1,
          needs_input_questions: [ "What should happen next?" ])

        post project_issue_clarifying_questions_path(project, issue), params: {
          questions: questions,
          answers: answers,
          queue: "dashboard_needs_input",
          queue_project_id: other_project.id,
          return_to: dashboard_needs_input_path(project_id: other_project.id)
        }

        expect(response).to redirect_to(dashboard_needs_input_path(project_id: other_project.id))
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
