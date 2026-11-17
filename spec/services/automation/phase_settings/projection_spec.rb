# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-008 @spec AUTOMATION-PHASES-019
RSpec.describe Automation::PhaseSettings::Projection do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }

  def grant_ids(key)
    described_class.call(project:).fetch(:grants).fetch(key).map { |grant| grant.fetch(:id) }
  end

  it "keeps every active grant discoverable when newer inactive history exceeds the history bound" do
    oldest_active = create(:work_item_continuation_grant, project:, issue:, created_at: 3.days.ago)
    create_list(:work_item_continuation_grant, described_class::INACTIVE_GRANT_LIMIT + 1,
      project:, issue:, created_at: 2.days.ago, revoked_at: 1.hour.ago)
    newer_active = create(:work_item_continuation_grant, project:, issue:, created_at: 1.day.ago)

    expect(grant_ids(:active)).to contain_exactly(oldest_active.id, newer_active.id)
  end

  it "bounds inactive history separately and reports truncation" do
    revoked = create_list(:work_item_continuation_grant, described_class::INACTIVE_GRANT_LIMIT,
      project:, issue:, created_at: 1.day.ago, revoked_at: 1.hour.ago)
    create(:work_item_continuation_grant, project:, issue:, created_at: 2.days.ago, completed_at: 1.hour.ago)

    grants = described_class.call(project:).fetch(:grants)

    expect(grants.fetch(:inactive)).to all(include(active: false, revoked_at: kind_of(ActiveSupport::TimeWithZone)))
    expect(revoked.map(&:id)).to all(be_in(grants.fetch(:inactive).map { |grant| grant.fetch(:id) }))
    expect(grants.fetch(:inactive_truncated)).to be(true)
  end

  it "lists inactive history without a truncation flag while under the bound" do
    inactive = create(:work_item_continuation_grant, project:, issue:, created_at: 2.days.ago, completed_at: 1.hour.ago)
    active = create(:work_item_continuation_grant, project:, issue:, created_at: 1.day.ago)

    grants = described_class.call(project:).fetch(:grants)

    expect(grants.fetch(:active).map { |grant| grant.fetch(:id) }).to contain_exactly(active.id)
    expect(grants.fetch(:inactive).map { |grant| grant.fetch(:id) }).to contain_exactly(inactive.id)
    expect(grants.fetch(:inactive_truncated)).to be(false)
  end

  it "orders both lists newest first" do
    older_active = create(:work_item_continuation_grant, project:, issue:, created_at: 2.days.ago)
    newer_active = create(:work_item_continuation_grant, project:, issue:, created_at: 1.day.ago)
    older_inactive = create(:work_item_continuation_grant, project:, issue:, created_at: 3.days.ago, revoked_at: 1.hour.ago)
    newer_inactive = create(:work_item_continuation_grant, project:, issue:, created_at: 2.days.ago,
      completed_at: 1.hour.ago)

    expect(grant_ids(:active)).to eq([ newer_active.id, older_active.id ])
    expect(grant_ids(:inactive)).to eq([ newer_inactive.id, older_inactive.id ])
  end
end
