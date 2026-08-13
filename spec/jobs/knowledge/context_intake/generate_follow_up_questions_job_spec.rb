# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::GenerateFollowUpQuestionsJob do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:session) { create(:context_intake_session, project: project, started_by: user) }

  describe "#perform" do
    it "re-raises the original error when marking generation failed also errors" do
      original_error = StandardError.new("generation failed")

      allow(ContextIntakeSession).to receive(:find).with(session.id).and_return(session)
      allow(Knowledge::ContextIntake::GenerateQuestions).to receive(:call).and_raise(original_error)
      allow(session).to receive(:update!).and_raise(ActiveRecord::StaleObjectError.new(session, :update))

      expect {
        described_class.perform_now(
          session_id: session.id,
          project_id: project.id,
          current_round: 1,
          blocking: true
        )
      }.to raise_error(StandardError, "generation failed")
    end
  end
end
