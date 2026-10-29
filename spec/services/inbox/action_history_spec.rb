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

  # @spec OPERATOR-INBOX-022
  it "returns every event exactly once across pages" do
    21.times do |index|
      create(:inbox_history_event, account: project.account, project:,
        subject_key: "issue:#{project.id}:#{issue.github_number}",
        occurred_at: index.minutes.ago, metadata: { action: "Event #{index}" })
    end

    first_page = described_class.call(entry:)
    second_page = described_class.call(entry:, before: first_page.next_cursor)

    expect(first_page.events.size).to eq(20)
    expect(second_page.events.size).to eq(1)
    expect(first_page.events.map(&:id) & second_page.events.map(&:id)).to be_empty
    expect(first_page.events.map(&:id) + second_page.events.map(&:id)).to match_array(
      InboxHistoryEvent.pluck(:id).map { |id| "history:#{id}" }
    )
  end

  # @spec OPERATOR-INBOX-022
  it "bounds each database history stream before merging" do
    25.times do |index|
      create(:inbox_history_event, account: project.account, project:,
        subject_key: "issue:#{project.id}:#{issue.github_number}", occurred_at: index.minutes.ago)
      create(:agent_run, :completed, project:, issue:, started_at: index.minutes.ago,
        completed_at: index.minutes.ago + 1.second)
    end

    selects = []
    callback = ->(*args) { selects << args.last[:sql] if args.last[:sql].start_with?("SELECT") }
    history = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.call(entry:, limit: 5)
    end

    expect(history.events.size).to eq(5)
    expect(history.next_cursor).to eq(history.events.last.id)
    history_selects = selects.grep(/FROM (?:"inbox_history_events"|"agent_runs")/)
    expect(history_selects).not_to be_empty
    expect(history_selects).to all(include("LIMIT"))
  end
end
