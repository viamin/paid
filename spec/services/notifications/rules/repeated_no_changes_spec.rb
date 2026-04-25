# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::RepeatedNoChanges do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project, github_updated_at: 5.days.ago) }

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  def add_no_changes_run(created_at:)
    create(:agent_run, :no_output, project: project, issue: issue,
      goal: "create_pr", created_at: created_at, completed_at: created_at + 5.minutes)
  end

  it "publishes after three consecutive no_changes runs" do
    add_no_changes_run(created_at: 3.days.ago)
    described_class.call(scope: [ issue ])
    add_no_changes_run(created_at: 2.days.ago)
    described_class.call(scope: [ issue ])
    add_no_changes_run(created_at: 1.day.ago)

    expect {
      described_class.call(scope: [ issue ])
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "repeated_no_changes", subject: issue)
    expect(notification.metadata["consecutive_runs"]).to eq(3)
  end

  it "does not publish below the threshold" do
    add_no_changes_run(created_at: 2.days.ago)
    described_class.call(scope: [ issue ])
    add_no_changes_run(created_at: 1.day.ago)

    expect {
      described_class.call(scope: [ issue ])
    }.not_to change(Notification, :count)
  end

  it "resolves when a run produces changes" do
    3.times do |index|
      add_no_changes_run(created_at: (3 - index).days.ago)
      described_class.call(scope: [ issue ])
    end
    create(:agent_run, :completed, project: project, issue: issue, created_at: 1.hour.ago, completed_at: 30.minutes.ago)

    described_class.call(scope: [ issue ])

    expect(Notification.find_by!(source: "repeated_no_changes", subject: issue).resolved_at).to be_present
  end

  it "deduplicates by issue" do
    3.times do |index|
      add_no_changes_run(created_at: (3 - index).days.ago)
      described_class.call(scope: [ issue ])
    end

    described_class.call(scope: [ issue ])

    expect(Notification.where(source: "repeated_no_changes", subject: issue).count).to eq(1)
  end
end
