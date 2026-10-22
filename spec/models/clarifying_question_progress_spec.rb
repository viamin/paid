# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestionProgress, type: :model do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:session) { create(:chat_session, account:, project:, clarifying_question_issue: issue) }

  it "requires the chat to be linked to the progress issue" do
    other_issue = create(:issue, project:)
    progress = described_class.new(
      account:, project:, issue: other_issue, chat_session: session,
      question: "What should happen?", question_digest: "digest", position: 1
    )

    expect(progress).to be_invalid
    expect(progress.errors[:chat_session]).to include("must be linked to the progress issue")
  end

  # @spec QUESTION-EXPLORATION-010
  # Progress teardown (session, issue, or account cascades) must clear its
  # investigations first because chat_investigations.clarifying_question_progress_id
  # is null:false.
  it "destroys its investigations before the progress record" do
    investigation = create(:chat_investigation)

    expect { investigation.clarifying_question_progress.destroy! }
      .to change(ChatInvestigation, :count).by(-1)
  end
end
