# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectDelegation::IntentCheckpoint::Resolve do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:user) { create(:user, account:) }
  let(:checkpoint) do
    ProjectDelegation::IntentCheckpoint::Plan.call(issue:, questions: [
      {
        "question" => "How long must imported metrics be retained?",
        "affected_scope" => "Data retention policy",
        "recommendation" => "Retain 30 days of imported metrics.",
        "consequences" => [ "Longer retention increases storage cost." ]
      },
      {
        "question" => "Which cache TTL is allowed?",
        "affected_scope" => "Cache policy",
        "recommendation" => "Use a 5-minute TTL."
      }
    ])
  end

  before do
    described_class # ensure autoloaded
    ProjectDelegation::IntentCheckpoint::Settle.call(checkpoint:, user:, disposition: "settled",
      answers: { "data-retention-policy" => "Retain 30 days.", "cache-policy" => "5-minute TTL." })
  end

  def resolve(question:, group_key: nil)
    described_class.call(issue:, question:, group_key:)
  end

  it "answers a settled question without re-asking or notifying" do  # @spec PROJECT-DELEGATION-002
    result = resolve(question: "How long must imported metrics be retained?")

    expect(result).to be_answered
    expect(result.answer).to eq("Retain 30 days.")
    expect(result.checkpoint).to eq(checkpoint)
    expect(Notification.where(source: described_class::NOTIFICATION_SOURCE).count).to eq(0)
  end

  it "answers by explicit group key when no question text is supplied" do  # @spec PROJECT-DELEGATION-002
    result = resolve(question: nil, group_key: "cache-policy")

    expect(result).to be_answered
    expect(result.answer).to eq("5-minute TTL.")
  end

  it "reports an unsettlement when no checkpoint covers the question" do  # @spec PROJECT-DELEGATION-002
    result = resolve(question: "Which branding should the dashboard use?")

    expect(result).to be_unsettled
    expect(result.checkpoint).to be_nil
    expect(Notification.where(source: described_class::NOTIFICATION_SOURCE).count).to eq(0)
  end

  it "routes one focused re-decision when the design revision changed" do  # @spec PROJECT-DELEGATION-002
    issue.update!(title: "A materially different request")

    result = resolve(question: "How long must imported metrics be retained?")

    expect(result).to be_re_decision
    expect(result.reasons).to include("design_revision")
    notification = Notification.find_by(source: described_class::NOTIFICATION_SOURCE)
    expect(notification).to be_blocking
    expect(notification.metadata).to include(
      "checkpoint_id" => checkpoint.id,
      "group_key" => "data-retention-policy",
      "reasons" => array_including("design_revision")
    )
  end

  it "routes a focused re-decision when the acceptance revision changed" do  # @spec PROJECT-DELEGATION-002
    assessment_run = create(:agent_run, :completed, project:, issue:)
    assessment_run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(
      assessment_run, { "criteria" => [ { "id" => "AC-1", "state" => "satisfied" } ], "gaps" => [] }
    ) })

    result = resolve(question: "Which cache TTL is allowed?")

    expect(result).to be_re_decision
    expect(result.reasons).to include("acceptance_revision")
  end

  it "reuses one focused re-decision for the same failed question" do  # @spec PROJECT-DELEGATION-002
    issue.update!(title: "A materially different request")

    2.times { resolve(question: "How long must imported metrics be retained?") }

    expect(Notification.where(source: described_class::NOTIFICATION_SOURCE).count).to eq(1)
  end

  it "does not reopen unrelated settled questions" do  # @spec PROJECT-DELEGATION-002
    issue.update!(title: "A materially different request")

    retention = resolve(question: "How long must imported metrics be retained?")
    cache = resolve(question: "Which cache TTL is allowed?")

    expect(retention).to be_re_decision
    expect(cache).to be_re_decision
    # Each routed decision names only the smallest group it re-opens; the
    # Inbox keeps one row per work item, refreshed to the latest group.
    expect(retention.notification.metadata["group_key"]).to eq("data-retention-policy")
    expect(cache.notification.metadata["group_key"]).to eq("cache-policy")
    notifications = Notification.where(source: described_class::NOTIFICATION_SOURCE)
    expect(notifications.count).to eq(1)
    expect(notifications.first.metadata["group_key"]).to eq("cache-policy")
  end

  it "does not consult superseded or pending checkpoints" do  # @spec PROJECT-DELEGATION-002
    superseded = ProjectDelegation::IntentCheckpoint::Plan.call(issue:, questions: [
      { "question" => "Which branding should the dashboard use?", "affected_scope" => "Branding",
        "recommendation" => "Keep current branding." }
    ])
    superseded.update!(status: "superseded")

    result = resolve(question: "Which branding should the dashboard use?")

    expect(result).to be_unsettled
  end
end
