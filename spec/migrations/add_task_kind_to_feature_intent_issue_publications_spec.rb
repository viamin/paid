# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261024224629_add_task_kind_to_feature_intent_issue_publications")
require Rails.root.join("db/migrate/20261024224630_enforce_task_kind_on_feature_intent_issue_publications")

RSpec.describe AddTaskKindToFeatureIntentIssuePublications, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:enforcement_migration) { EnforceTaskKindOnFeatureIntentIssuePublications.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:receipt_class) { Class.new(ActiveRecord::Base) { self.table_name = "feature_intent_issue_publications" } }
  let(:feature_intent) { create(:feature_intent) }

  around do |example|
    enforcement_migration.migrate(:down) unless task_kind_column.null
    migration.migrate(:down) if connection.column_exists?(:feature_intent_issue_publications, :task_kind)
    receipt_class.reset_column_information
    example.run
  ensure
    migration.migrate(:up) unless connection.column_exists?(:feature_intent_issue_publications, :task_kind)
    enforcement_migration.migrate(:up) if task_kind_column.null
    receipt_class.reset_column_information
    FeatureIntentIssuePublication.reset_column_information
    receipt = FeatureIntentIssuePublication.find_by(task_digest: "legacy-receipt")
    FeatureIntent.find_by_id(receipt.feature_intent_id)&.destroy! if receipt
    receipt&.destroy!
  end

  # @spec CONFIDENCE-DELIVERY-017
  it "backfills existing publication receipts before enforcing their task kind" do
    receipt = receipt_class.create!(feature_intent_id: feature_intent.id, task_digest: "legacy-receipt")

    migration.migrate(:up)
    receipt_class.reset_column_information

    expect(receipt_class.find(receipt.id).task_kind).to eq("implementation")
    expect(task_kind_column.null).to be(true)

    enforcement_migration.migrate(:up)

    expect(task_kind_column.null).to be(false)
  end

  private

  def task_kind_column
    connection.columns(:feature_intent_issue_publications).find { |column| column.name == "task_kind" }
  end
end
