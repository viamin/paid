# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::FindEntry do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, :needs_input, project:, needs_input_questions: [ "What should happen?" ]) }

  # @spec MOBILE-API-008
  it "re-resolves only the entry's queue lane" do
    entry = described_class.call(user:, entry_id: "clarifying_questions:#{issue.id}")

    expect(entry).to have_attributes(id: "clarifying_questions:#{issue.id}")
  end

  # @spec MOBILE-API-008
  it "returns nil for malformed and stale ids" do
    expect(described_class.call(user:, entry_id: "not-a-queue-id")).to be_nil
    expect(described_class.call(user:, entry_id: "clarifying_questions:999999")).to be_nil
  end
end
