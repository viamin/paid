# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260824143808_add_needs_input_since_to_issues")

RSpec.describe AddNeedsInputSinceToIssues, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }

  after do
    cleanup_records
  end

  it "is reversible and backfills existing needs_input issues on re-apply" do
    issue = create_needs_input_issue
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

  def cleanup_records
    models = [
      Issue,
      Project,
      Account
    ]

    models.each(&:delete_all)
    models.each { |model| ActiveRecord::Base.connection.reset_pk_sequence!(model.table_name) }
  end

  def create_needs_input_issue
    account = Account.create!(
      name: "Migration Spec Account #{SecureRandom.hex(4)}",
      slug: "migration-spec-account-#{SecureRandom.hex(4)}"
    )

    project = Project.create!(
      account: account,
      github_token: nil,
      created_by: nil,
      name: "Migration Spec Project",
      github_id: rand(1_000_000_000),
      owner: "migration-owner",
      repo: "migration-repo",
      active: false,
      poll_interval_seconds: 60,
      default_branch: "main",
      allowed_github_usernames: [ "viamin" ]
    )

    Issue.create!(
      project: project,
      github_issue_id: rand(1_000_000_000),
      github_number: 1,
      title: "Needs input issue",
      body: "Body",
      github_creator_login: "viamin",
      github_state: "open",
      paid_state: "needs_input",
      labels: [ project.enhance_issue_needs_input_label_name ],
      github_created_at: 1.day.ago,
      github_updated_at: Time.current
    )
  end
end
