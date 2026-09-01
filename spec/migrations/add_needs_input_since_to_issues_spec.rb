# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260824143808_add_needs_input_since_to_issues")

RSpec.describe AddNeedsInputSinceToIssues, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }

  after do
    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE
        issues,
        projects,
        account_memberships,
        user_settings,
        tenant_settings,
        users,
        accounts
      RESTART IDENTITY CASCADE
    SQL
  end

  it "is reversible and backfills existing needs_input issues on re-apply" do
    issue = create(:issue, :needs_input)
    issue.update_column(:needs_input_since, nil)

    migration.down
    Issue.reset_column_information
    expect(Issue.column_names).not_to include("needs_input_since")

    migration.up
    Issue.reset_column_information

    expect(Issue.column_names).to include("needs_input_since")
    expect(issue.reload.needs_input_since).to be_within(1.second).of(issue.updated_at)
    expect(
      ActiveRecord::Base.connection.index_exists?(:issues, :needs_input_since, name: described_class::INDEX_NAME)
    ).to be(true)
  end

  it "drops an invalid leftover concurrent index before recreating it" do
    allow(migration).to receive(:index_exists?).with(:issues, :needs_input_since, name: described_class::INDEX_NAME).and_return(true)
    allow(migration).to receive(:index_valid?).with(described_class::INDEX_NAME).and_return(false, false)
    allow(migration).to receive(:safety_assured).and_yield

    expect(migration).to receive(:execute)
      .with("DROP INDEX CONCURRENTLY IF EXISTS #{described_class::INDEX_NAME}")
      .ordered
    expect(migration).to receive(:execute)
      .with(a_string_including("CREATE INDEX CONCURRENTLY #{described_class::INDEX_NAME}"))
      .ordered

    migration.send(:ensure_needs_input_since_index!)
  end
end
