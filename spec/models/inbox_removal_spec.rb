# frozen_string_literal: true

require "rails_helper"

RSpec.describe InboxRemoval do
  # @spec INBOX-PHASE-RELEVANCE-008
  it "does not let a delayed restore clear a newer removal of the same occurrence" do
    removal = described_class.create!(
      user: create(:user), request_key: "clarifying_questions:123",
      entry_kind: "clarifying_questions", request_occurrence: "2026-11-16T07:40:00.000000Z",
      removed_at: 2.minutes.ago
    )
    delayed_restore = described_class.find(removal.id)
    removal.clear!
    removal.update!(cleared_at: nil, removed_at: Time.current)

    expect { expect(delayed_restore.clear!).to be(false) }
      .not_to change { removal.reload.attributes }
    expect(removal).to be_active
  end

  # @spec INBOX-PHASE-RELEVANCE-008
  it "clears a matching removal only once across stale instances" do
    removal = described_class.create!(
      user: create(:user), request_key: "clarifying_questions:123",
      entry_kind: "clarifying_questions", request_occurrence: "2026-11-16T07:40:00.000000Z",
      removed_at: Time.current
    )
    delayed_restore = described_class.find(removal.id)

    expect(removal.clear!).to be(true)
    expect { expect(delayed_restore.clear!).to be(false) }
      .not_to change { removal.reload.cleared_at }
  end

  # @spec INBOX-PHASE-RELEVANCE-008
  it "enforces one removal per user and stable request identity at the database boundary" do
    user = create(:user)
    other_account_user = create(:user, account: create(:account))
    attributes = {
      user_id: user.id,
      request_key: "clarifying_questions:123",
      entry_kind: "clarifying_questions",
      request_occurrence: "2026-11-16T07:40:00.000000Z",
      removed_at: Time.current,
      created_at: Time.current,
      updated_at: Time.current
    }

    described_class.insert_all!([ attributes ])

    expect do
      described_class.transaction(requires_new: true) do
        described_class.insert_all!([ attributes.merge(request_occurrence: "2026-11-16T07:41:00.000000Z") ])
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)

    expect do
      described_class.insert_all!([ attributes.merge(user_id: other_account_user.id) ])
    end.not_to raise_error
  end
end
