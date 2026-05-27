# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Knowledge::ContextIntake" do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:session) { create(:context_intake_session, project: project, started_by: user) }
  let(:questions) do
    Knowledge::ContextIntake::QuestionnaireSchema.sections.flat_map do |section|
      section[:questions].map { |question| question.merge(section_key: section[:key]) }
    end
  end
  let(:first_question) { questions.first }
  let(:second_question) { questions.second }
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
    it "keeps required questions in place when navigating forward without an answer" do
      session.context_intake_responses.find_by!(question_key: first_question.fetch(:key))
             .update!(answer_text: nil)

      patch project_context_intake_path(project),
        params: {
          question_key: first_question.fetch(:key),
          answer_text: "",
          navigation_action: "next"
        },
        headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Please answer this required question before continuing.")
      expect(response.body).to include(first_question.fetch(:text))
      expect(response.body).not_to include(second_question.fetch(:text))
    end

    it "renders the next round when follow-up questions are generated instead of completing immediately" do
      session.context_intake_responses.find_by!(question_key: first_question.fetch(:key))
             .update!(answer_text: "Enterprise workflow answer")
      create_follow_up_question!(first_question.fetch(:key))
      FeatureFlags.disable!(:context_intake_agent_questions)

      patch project_context_intake_path(project),
        params: {
          question_key: last_question.fetch(:key),
          answer_text: "Final answer",
          navigation_action: "finish"
        },
        headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Which enterprise approvals or governance steps block releases?")
      expect(response.body).to include("Question 18 of 18")
    end

    it "redirects turbo-frame finish submissions to the full page with a success notice" do
      allow(Knowledge::ContextIntake::GenerateQuestions).to receive(:call).and_return([])

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
      allow(Knowledge::ContextIntake::GenerateQuestions).to receive(:call).and_return([])

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

    it "renders a validation error instead of raising when finish navigation references a missing question" do
      allow(Knowledge::ContextIntake::GenerateQuestions).to receive(:call).and_return([])

      patch project_context_intake_path(project),
        params: {
          question_key: "missing_question",
          answer_text: "Final answer",
          navigation_action: "finish"
        },
        headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t find ContextIntakeResponse")
      expect(response.body).to include(last_question.fetch(:text))
    end

    it "invokes AI question generation when the feature flag is enabled" do
      FeatureFlags.enable!(:context_intake_agent_questions, project:)

      expect {
        patch project_context_intake_path(project),
          params: {
            question_key: last_question.fetch(:key),
            answer_text: "Final answer",
            navigation_action: "finish"
          },
          headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }
      }.to have_enqueued_job(Knowledge::ContextIntake::GenerateFollowUpQuestionsJob)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Generating follow-up questions")
    end

    it "completes immediately when AI generation was already attempted for the round" do
      FeatureFlags.enable!(:context_intake_agent_questions, project:)
      session.update!(metadata: { "follow_up_generation_attempted_rounds" => [ 1 ] })

      expect {
        patch project_context_intake_path(project),
          params: {
            question_key: last_question.fetch(:key),
            answer_text: "Final answer",
            navigation_action: "finish"
          },
          headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }
      }.not_to have_enqueued_job(Knowledge::ContextIntake::GenerateFollowUpQuestionsJob)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(project_context_intake_path(project))
    end

    it "redirects instead of falling through when finish round returns an unexpected terminal state" do
      allow(Knowledge::ContextIntake::FinishRound).to receive(:call).and_return(
        instance_double(
          Knowledge::ContextIntake::FinishRound::Result,
          next_question_key: nil,
          pending_generation?: false,
          completed?: false
        )
      )

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
    end

    it "does not invoke AI question generation when the feature flag is disabled" do
      FeatureFlags.disable!(:context_intake_agent_questions)

      expect {
        patch project_context_intake_path(project),
          params: {
            question_key: last_question.fetch(:key),
            answer_text: "Final answer",
            navigation_action: "finish"
          },
          headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }
      }.not_to have_enqueued_job(Knowledge::ContextIntake::GenerateFollowUpQuestionsJob)
    end

    it "renders the pending frame while AI follow-up generation is in progress" do
      FeatureFlags.enable!(:context_intake_agent_questions, project:)
      session.update!(metadata: { "follow_up_generation" => { "status" => "pending", "round" => 2, "blocking" => true } })

      get project_context_intake_path(project),
        headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Generating follow-up questions")
    end

    it "clears blocking follow-up generation failures on full-page reloads" do
      FeatureFlags.enable!(:context_intake_agent_questions, project:)
      session.update!(
        metadata: {
          "follow_up_generation" => {
            "status" => "failed",
            "round" => 2,
            "blocking" => true,
            "error_class" => "StandardError",
            "error" => "generation failed"
          }
        }
      )

      get project_context_intake_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(last_question.fetch(:text))
      expect(response.body).not_to include("Follow-up question generation failed. Reload the page to retry.")
      expect(session.reload.follow_up_generation_state).to eq({})
    end

    it "keeps the full-page wizard reachable during non-blocking follow-up generation" do
      create_follow_up_question!(first_question.fetch(:key))
      session.context_intake_responses.find_by!(question_key: last_question.fetch(:key))
             .update!(answer_text: nil)
      session.update!(metadata: { "follow_up_generation" => { "status" => "pending", "round" => 2, "blocking" => false } })

      get project_context_intake_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(last_question.fetch(:text))
      expect(response.body).not_to include("Generating follow-up questions")
    end

    it "keeps the turbo-frame wizard reachable during non-blocking follow-up generation" do
      create_follow_up_question!(first_question.fetch(:key))
      session.context_intake_responses.find_by!(question_key: last_question.fetch(:key))
             .update!(answer_text: nil)
      session.update!(metadata: { "follow_up_generation" => { "status" => "pending", "round" => 2, "blocking" => false } })

      get project_context_intake_path(project),
        headers: { "Turbo-Frame" => Knowledge::ContextIntakeController::WIZARD_FRAME_ID }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(last_question.fetch(:text))
      expect(response.body).not_to include("Generating follow-up questions")
    end
  end

  def create_follow_up_question!(parent_question_key)
    create(
      :context_intake_question,
      project: project,
      key: "enterprise_approvals",
      question_text: "Which enterprise approvals or governance steps block releases?",
      section_key: "operational_constraints",
      section_title: "Operational & Business Constraints",
      category: "operational_constraints",
      round: 2,
      section_order: 6,
      display_order: 0,
      is_follow_up: true,
      parent_question_key: parent_question_key,
      conditions: {
        "depends_on_question_key" => parent_question_key,
        "answer_includes_any" => [ "enterprise" ]
      }
    )
  end
end
