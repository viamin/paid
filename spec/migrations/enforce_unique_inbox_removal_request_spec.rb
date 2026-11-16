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

  # @spec INBOX-PHASE-RELEVANCE-008
  it "retries concurrent unique-index build races until the index can be created" do
    allow(migration).to receive(:deduplicate_removals)
    allow(migration).to receive(:remove_failed_index)
    allow(migration).to receive(:unique_violation?).and_return(true)
    allow(migration).to receive(:say)
    fail_build_attempts(migration, 2)

    expect { migration.migrate(:up) }.not_to raise_error
    expect(migration).to have_received(:deduplicate_removals).exactly(3).times
    expect(migration).to have_received(:remove_failed_index).twice
    expect(migration).to have_received(:say).twice
  end

  # @spec INBOX-PHASE-RELEVANCE-008
  it "raises after bounded concurrent unique-index build retries" do
    allow(migration).to receive(:deduplicate_removals)
    allow(migration).to receive(:remove_failed_index)
    allow(migration).to receive(:unique_violation?).and_return(true)
    allow(migration).to receive(:say)
    fail_build_attempts(migration, described_class::MAX_INDEX_BUILD_ATTEMPTS)

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::StatementInvalid, "duplicate rows")
    expect(migration).to have_received(:deduplicate_removals)
      .exactly(described_class::MAX_INDEX_BUILD_ATTEMPTS).times
    expect(migration).to have_received(:remove_failed_index)
      .exactly(described_class::MAX_INDEX_BUILD_ATTEMPTS).times
    expect(migration).to have_received(:say).exactly(described_class::MAX_INDEX_BUILD_ATTEMPTS).times
  end

  private

  def fail_build_attempts(migration, count)
    attempts = 0
    allow(migration).to receive(:add_unique_index) do
      attempts += 1
      raise ActiveRecord::StatementInvalid, "duplicate rows" if attempts <= count
    end
  end

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
