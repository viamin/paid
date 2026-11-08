# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::FocusedDecision do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:base_args) do
    {
      account: account,
      subject: issue,
      source: "delegated_work_boundary_recheck",
      title: "Delegated work needs a focused decision",
      description: "Delegated work is paused until its current authority is reviewed."
    }
  end

  def metadata(authorization_id:, boundary:, reasons:)
    { "authorization_id" => authorization_id, "boundary" => boundary, "reasons" => reasons }
  end

  def call(metadata:, **overrides)
    described_class.call(**base_args, metadata: metadata, **overrides)
  end

  it "creates one blocking error notification for a focused decision" do
    notification = call(metadata: metadata(authorization_id: 1, boundary: "queue", reasons: [ "trust" ]))

    expect(notification).to be_persisted
    expect(notification).to be_blocking
    expect(notification.severity).to eq("error")
    expect(notification.metadata).to include("boundary" => "queue", "reasons" => [ "trust" ])
    expect(notification.action_url).to eq("/inbox/action_required:#{notification.id}")
  end

  it "reuses the existing notification for an equivalent decision identity" do
    first = call(metadata: metadata(authorization_id: 1, boundary: "queue", reasons: [ "trust" ]))
    second = call(metadata: metadata(authorization_id: 1, boundary: "queue", reasons: [ "trust" ]))

    expect(second.id).to eq(first.id)
    expect(Notification.count).to eq(1)
  end

  it "keeps a dismissed equivalent decision dismissed instead of re-prompting" do
    first = call(metadata: metadata(authorization_id: 1, boundary: "queue", reasons: [ "trust" ]))
    first.update!(dismissed_at: Time.current)

    second = call(metadata: metadata(authorization_id: 1, boundary: "queue", reasons: [ "trust" ]))

    expect(second.id).to eq(first.id)
    expect(second.reload.dismissed_at).to be_present
    expect(Notification.count).to eq(1)
  end

  it "refreshes the active notification when a later failure has a different identity" do
    original = call(metadata: metadata(authorization_id: 1, boundary: "queue", reasons: [ "trust" ]))
    original.update!(read_at: Time.current)

    refreshed = call(
      metadata: metadata(authorization_id: 2, boundary: "dequeue", reasons: [ "budget" ]),
      title: "Updated title"
    )

    expect(Notification.count).to eq(1)
    expect(refreshed.metadata).to include(
      "authorization_id" => 2, "boundary" => "dequeue", "reasons" => [ "budget" ]
    )
    expect(refreshed.title).to eq("Updated title")
    expect(refreshed.read_at).to be_nil
  end

  it "revives a dismissed notification when a different failure needs representation" do
    first = call(metadata: metadata(authorization_id: 1, boundary: "queue", reasons: [ "trust" ]))
    first.update!(dismissed_at: Time.current, resolved_at: Time.current)

    revived = call(metadata: metadata(authorization_id: 1, boundary: "queue", reasons: [ "budget" ]))

    expect(revived.id).to eq(first.id)
    expect(revived.reload).to be_active
    expect(revived.metadata["reasons"]).to eq([ "budget" ])
  end
end
