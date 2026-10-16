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
end
