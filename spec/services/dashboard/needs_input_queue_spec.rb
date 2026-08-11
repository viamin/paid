# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::NeedsInputQueue do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true, owner: "acme", repo: "alpha")
  end
  let(:first_issue) { create(:issue, :needs_input, project: project, github_number: 10, body: questions_body) }
  let(:second_issue) { create(:issue, :needs_input, project: project, github_number: 11, body: questions_body) }
  let(:questions_body) do
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
    BODY
  end

  describe ".call" do
    it "returns clarifying questions persisted locally for create_feature issues without an API round-trip" do
      feature_issue = create(:issue, :needs_input, project: project, github_number: 20,
                             body: "Need dark mode",
                             needs_input_questions: [
                               "What is the desired behavior?",
                               "What constraints must be respected?"
                             ])

      entries = described_class.call(user: user, project: project)

      feature_entry = entries.find { |entry| entry.issue == feature_issue }
      expect(feature_entry.questions).to eq([
        "What is the desired behavior?",
        "What constraints must be respected?"
      ])
    end
  end

  describe ".next_issue" do
    it "returns the following issue when the current issue is still in the queue" do
      first_issue
      second_issue

      expect(described_class.next_issue(user: user, project: project, after_issue: first_issue)).to eq(second_issue)
    end

    it "returns nil when after_issue is no longer in the queue" do
      second_issue
      stale_issue = create(:issue, project: project, github_number: 9, paid_state: "new", body: questions_body)

      expect(described_class.next_issue(user: user, project: project, after_issue: stale_issue)).to be_nil
    end
  end
end
