# frozen_string_literal: true

require "rails_helper"

# @spec QUEUE-DIAGNOSIS-001 QUEUE-DIAGNOSIS-002
RSpec.describe Dashboard::QueueDiagnosis do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  it "identifies eligible work that has not reached the backend queue" do
    account = create(:account)
    user = create(:user, account: account)
    project = create(:project, account: account, created_by: user, auto_pick_enabled: true)
    issue = create(:issue, project: project, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user: user).first

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.items.map(&:issue)).to eq([ issue ])
    expect(diagnosis.next_action).to eq(:wait_for_eligibility_sweep)
  end

  it "does not report a failure while eligible work is actively running" do
    account = create(:account)
    user = create(:user, account: account)
    project = create(:project, account: account, created_by: user, auto_pick_enabled: true)
    issue = create(:issue, project: project, github_state: "open", paid_state: "new")
    create(:agent_run, :running, :automatic, project: project, issue: issue)

    diagnosis = described_class.call(user: user).first

    expect(diagnosis.state).to eq(:healthy_active_work)
    expect(diagnosis.active_count).to eq(1)
    expect(diagnosis.eligible_count).to eq(0)
  end

  it "names a human-input hold and routes it to the Inbox" do
    account = create(:account)
    user = create(:user, account: account)
    project = create(:project, account: account, created_by: user, auto_pick_enabled: true)
    issue = create(:issue, project: project, github_state: "open", paid_state: "needs_input", labels: [ "needs input" ],
      needs_input_questions: [ "Which behaviour is intended?" ])

    diagnosis = described_class.call(user: user).first

    expect(diagnosis.state).to eq(:human_or_dependency_hold)
    expect(diagnosis.items.first.issue).to eq(issue)
    expect(diagnosis.items.first.kind).to eq(:needs_input)
    expect(diagnosis.next_action).to eq(:open_inbox)
  end

  it "reports a deliberate project pause instead of attempting recovery" do
    account = create(:account)
    user = create(:user, account: account)
    create(:project, account: account, created_by: user, auto_pick_enabled: true,
      scheduler_paused_at: Time.current)

    diagnosis = described_class.call(user: user).first

    expect(diagnosis.state).to eq(:resource_or_policy_pause)
    expect(diagnosis.next_action).to eq(:resume_project)
  end

  it "keeps a diagnosis outage visibly unknown" do
    account = create(:account)
    user = create(:user, account: account)
    allow(Project).to receive(:where).and_raise(ActiveRecord::ConnectionNotEstablished)

    diagnosis = described_class.call(user: user).first

    expect(diagnosis.state).to eq(:unknown)
    expect(diagnosis.next_action).to eq(:refresh)
  end
end
