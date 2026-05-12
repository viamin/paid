# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Knowledge::ContextIntake" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:session) { create(:context_intake_session, project: project, started_by: user) }
  let(:questions) do
    Knowledge::ContextIntake::QuestionnaireSchema.sections.flat_map do |section|
      section[:questions].map { |question| question.merge(section_key: section[:key]) }
    end
  end
  let(:last_question) { questions.last }

  before do
    sign_in user

    questions.each_with_index do |question, index|
      create(
        :context_intake_response,
        context_intake_session: session,
        question_key: question.fetch(:key),
        question_text: question.fetch(:text),
        section: question.fetch(:section_key),
        sequence: index,
        answer_text: index == questions.length - 1 ? nil : "Answer #{index}"
      )
    end
  end

  describe "GET /projects/:project_id/context_intake" do
    it "marks completed pages for full reload when loaded from a turbo frame" do
      session.update!(status: "completed", completed_at: Time.current)

      get project_context_intake_path(project),
        headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(name="turbo-visit-control" content="reload"))
      expect(response.body).to include("Business context captured")
    end
  end

  describe "PATCH /projects/:project_id/context_intake" do
    it "redirects turbo-frame finish submissions to the full page with a success notice" do
      patch project_context_intake_path(project),
        params: {
          question_key: last_question.fetch(:key),
          answer_text: "Final answer",
          navigation_action: "finish"
        },
        headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(project_context_intake_path(project))
      expect(flash[:notice]).to eq("Business context saved and synthesized into project knowledge.")

      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Business context saved and synthesized into project knowledge.")
      expect(response.body).to include("Business context captured")
    end

    it "redirects turbo-frame skip-finish submissions to the full page with a success notice" do
      patch project_context_intake_path(project),
        params: {
          question_key: last_question.fetch(:key),
          answer_text: "",
          navigation_action: "skip_finish"
        },
        headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(project_context_intake_path(project))
      expect(flash[:notice]).to eq("Business context saved and synthesized into project knowledge.")

      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Business context saved and synthesized into project knowledge.")
      expect(response.body).to include("Business context captured")
    end
  end
end
