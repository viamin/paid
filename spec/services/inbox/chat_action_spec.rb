# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ChatAction do
  it "provides exactly one contextual-chat entry point for every inbox kind" do
    # @spec OPERATOR-INBOX-002I
    specialized_kinds = {
      Inbox::Queue::CLARIFYING_QUESTIONS_KIND => "Answer in chat",
      Inbox::Queue::RETRY_LIMITED_KIND => "Investigate in chat",
      Inbox::Queue::CHANGE_INTENT_DRAFT_KIND => "Chat about this"
    }

    expect(Inbox::Queue::KINDS).to all(satisfy { |kind| described_class.for(kind).label.present? })
    expect(Inbox::Queue::KINDS.select { |kind| described_class.for(kind).shared_detail? })
      .to match_array(Inbox::Queue::KINDS - specialized_kinds.keys)
    specialized_kinds.each do |kind, label|
      expect(described_class.for(kind)).to have_attributes(label:, shared_detail?: false)
    end
  end
end
