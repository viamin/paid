# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261116073909_enforce_unique_inbox_removal_request")

RSpec.describe EnforceUniqueInboxRemovalRequest do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:user) { create(:user) }
  let(:request_key) { "clarifying_questions:migration-duplicate" }

  around do |example|
    migration.migrate(:down)
    example.run
  ensure
    InboxRemoval.where(request_key:).delete_all
    migration.migrate(:up) unless ActiveRecord::Base.connection.index_exists?(:inbox_removals, name: described_class::INDEX_NAME)
  end

  # @spec INBOX-PHASE-RELEVANCE-008
  it "keeps the latest suppression state when legacy duplicate rows exist" do
    older = insert_removal(removed_at: 2.hours.ago, cleared_at: nil, updated_at: 2.hours.ago)
    newer = insert_removal(removed_at: 1.hour.ago, cleared_at: 30.minutes.ago, updated_at: 30.minutes.ago)

    expect { migration.migrate(:up) }.not_to raise_error

    expect(InboxRemoval.where(user:, request_key:).pluck(:id)).to contain_exactly(newer.id)
    expect(InboxRemoval.find(newer.id).cleared_at).to be_present
    expect(InboxRemoval.exists?(older.id)).to be(false)
  end

  private

  def insert_removal(removed_at:, cleared_at:, updated_at:)
    InboxRemoval.insert_all!([ {
      user_id: user.id,
      request_key:,
      entry_kind: "clarifying_questions",
      request_occurrence: updated_at.iso8601(6),
      removed_at:,
      cleared_at:,
      created_at: removed_at,
      updated_at:
    } ])
    InboxRemoval.find_by!(user:, request_key:, request_occurrence: updated_at.iso8601(6))
  end
end
