# frozen_string_literal: true

require "rails_helper"

RSpec.describe InboxRemoval do
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
