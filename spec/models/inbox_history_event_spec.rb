# frozen_string_literal: true

require "rails_helper"

RSpec.describe InboxHistoryEvent, type: :model do
  it "deduplicates a replayed event within its stable subject" do
    event = create(:inbox_history_event, event_key: "removal:1")

    duplicate = build(:inbox_history_event, account: event.account, project: event.project,
      subject_key: event.subject_key, event_key: event.event_key)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:event_key]).to be_present
  end
end
