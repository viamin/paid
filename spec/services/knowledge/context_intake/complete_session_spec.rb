# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::CompleteSession do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }

  describe ".call" do
    it "marks the session as completed and synthesizes knowledge" do
      session = Knowledge::ContextIntake::StartSession.call(project: project, user: user)

      # Answer all required questions
      Knowledge::ContextIntake::QuestionnaireSchema.required_questions.each do |q|
        Knowledge::ContextIntake::SaveResponse.call(
          session: session,
          question_key: q[:key],
          answer_text: "Test answer for #{q[:key]}"
        )
      end

      result = described_class.call(session: session)

      expect(result.status).to eq("completed")
      expect(result.completed_at).to be_present
    end

    it "raises when required questions are unanswered" do
      session = Knowledge::ContextIntake::StartSession.call(project: project, user: user)

      expect {
        described_class.call(session: session)
      }.to raise_error(ActiveRecord::RecordInvalid, /Required questions not answered/)
    end

    it "raises when required questions are skipped but not answered" do
      session = Knowledge::ContextIntake::StartSession.call(project: project, user: user)

      # Answer all required questions except one, which we mark as skipped directly
      required = Knowledge::ContextIntake::QuestionnaireSchema.required_questions
      required.each_with_index do |q, i|
        if i == 0
          # Simulate a crafted request that bypasses the UI skip guard
          session.context_intake_responses
                 .find_by!(question_key: q[:key])
                 .update_columns(skipped: true, answer_text: nil)
        else
          Knowledge::ContextIntake::SaveResponse.call(
            session: session,
            question_key: q[:key],
            answer_text: "Test answer"
          )
        end
      end

      expect {
        described_class.call(session: session)
      }.to raise_error(ActiveRecord::RecordInvalid, /Required questions not answered/)
    end

    it "creates knowledge artifacts for answered sections" do
      session = Knowledge::ContextIntake::StartSession.call(project: project, user: user)

      # Answer required + one optional
      Knowledge::ContextIntake::QuestionnaireSchema.required_questions.each do |q|
        Knowledge::ContextIntake::SaveResponse.call(
          session: session,
          question_key: q[:key],
          answer_text: "Answer for #{q[:key]}"
        )
      end

      described_class.call(session: session)

      artifacts = KnowledgeArtifact.for_project(project).active.by_type("business_context")
      expect(artifacts.count).to be > 0
      expect(artifacts.first.collector_type).to eq("context_intake")
    end
  end
end
