# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::StartSession do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }

  describe ".call" do
    it "creates a new in_progress session" do
      session = described_class.call(project: project, user: user)

      expect(session).to be_persisted
      expect(session.status).to eq("in_progress")
      expect(session.started_by).to eq(user)
      expect(session.project).to eq(project)
      expect(session.schema_version).to eq("1.0")
    end

    it "pre-populates responses from the questionnaire schema" do
      session = described_class.call(project: project, user: user)

      total = Knowledge::ContextIntake::QuestionnaireSchema.total_questions
      expect(session.context_intake_responses.count).to eq(total)
    end

    it "creates responses with correct attributes" do
      session = described_class.call(project: project, user: user)
      response = session.context_intake_responses.find_by(question_key: "product_description")

      expect(response).to be_present
      expect(response.section).to eq("product_purpose")
      expect(response.is_follow_up).to be(false)
      expect(response.provenance).to eq("human")
    end

    it "archives prior completed sessions" do
      old_session = create(:context_intake_session, :completed,
        project: project, started_by: user)

      described_class.call(project: project, user: user)

      expect(old_session.reload.status).to eq("archived")
    end
  end
end
