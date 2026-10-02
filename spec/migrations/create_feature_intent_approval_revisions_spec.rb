# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261002034147_create_feature_intent_approval_revisions")

# @spec FEATURE-APPROVAL-020 @spec FEATURE-APPROVAL-022
RSpec.describe CreateFeatureIntentApprovalRevisions, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    table_existed = connection.table_exists?(:feature_intent_approval_revisions)
    connection.drop_table(:feature_intent_approval_revisions, if_exists: true)
    example.run
  ensure
    connection.drop_table(:feature_intent_approval_revisions, if_exists: true)
    migration.migrate(:up) if table_existed
  end

  it "creates an append-only approval snapshot table with tenant RLS" do
    migration.migrate(:up)

    columns = connection.columns(:feature_intent_approval_revisions).index_by(&:name)
    expect(columns.fetch("approved_at").null).to be(false)
    expect(columns.fetch("pr_heads").null).to be(false)
    expect(connection.indexes(:feature_intent_approval_revisions).map(&:name))
      .to include("index_feature_intent_approval_revisions_unique_revision")
    expect(connection.foreign_key_exists?(:feature_intent_approval_revisions, :feature_intents)).to be(true)
    expect(rls_enabled?).to be(true)
  end

  it "installs BEFORE UPDATE and BEFORE DELETE triggers that reject mutations" do
    migration.migrate(:up)

    expect(trigger_exists?("prevent_feature_intent_approval_revision_update")).to be(true)
    expect(trigger_exists?("prevent_feature_intent_approval_revision_delete")).to be(true)
  end

  it "rolls back cleanly" do
    migration.migrate(:up)

    expect { migration.migrate(:down) }.not_to raise_error
    expect(connection.data_source_exists?("feature_intent_approval_revisions")).to be(false)
    expect(trigger_exists?("prevent_feature_intent_approval_revision_update")).to be(false)
    expect(trigger_exists?("prevent_feature_intent_approval_revision_delete")).to be(false)
  end

  it "can be rerun after a partial migration" do
    migration.migrate(:up)

    expect { migration.migrate(:up) }.not_to raise_error
  end

  private

  def rls_enabled?
    return false unless connection.data_source_exists?("feature_intent_approval_revisions")

    connection.select_value(
      "SELECT relrowsecurity FROM pg_class WHERE oid = 'public.feature_intent_approval_revisions'::regclass"
    ).then { |value| value == true || value == "t" }
  end

  def trigger_exists?(name)
    return false unless connection.data_source_exists?("feature_intent_approval_revisions")

    connection.select_value(<<~SQL.squish) == true
      SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = '#{name}'
            AND tgrelid = 'public.feature_intent_approval_revisions'::regclass
      )
    SQL
  end
end
