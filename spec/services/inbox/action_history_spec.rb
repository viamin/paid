# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ActionHistory do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project:) }
  let(:entry) do
    Inbox::Queue::Entry.new(id: "merge_approval:#{issue.id}", kind: "merge_approval", project:, issue:, record: issue,
      waiting_since: Time.current, questions: [], tasks: [], summary_text: "Review", title_text: issue.title, action_url: issue.github_url)
  end

  # @spec OPERATOR-INBOX-022
  it "orders durable transitions and failed then completed runs without conflating their results" do
    create(:inbox_history_event, account: project.account, project:, subject_key: "issue:#{project.id}:#{issue.github_number}",
      event_key: "approval", occurred_at: 3.hours.ago, actor_label: "octocat", source: "github", result: "completed",
      metadata: { action: "Owner approved" })
    create(:agent_run, project:, issue:, status: "failed", started_at: 2.hours.ago, completed_at: 90.minutes.ago)
    create(:agent_run, project:, issue:, status: "completed", started_at: 1.hour.ago, completed_at: 30.minutes.ago)

    history = described_class.call(entry:)

    expect(history.events.map(&:result)).to include("failed", "completed")
    expect(history.events.map(&:occurred_at)).to eq(history.events.map(&:occurred_at).sort.reverse)
    expect(history.events.first.action).to eq("Agent run completed")
  end

  # @spec OPERATOR-INBOX-023
  it "marks a subject with no local evidence as legacy-incomplete" do
    expect(described_class.call(entry:).incomplete).to be(true)
  end
end
