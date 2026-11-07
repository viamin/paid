# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261106235102_add_source_revision_to_facet_confidence_evaluation_generation_index")

# The evaluation-generation unique key includes the closeout's recorded source
# revision, so a revision change can start a new generation instead of
# stranding the operator on a frozen row (#4902 review). Rolling back must stay
# viable only while no closeout holds multiple generations: the legacy
# (issue_id, corpus_digest) key cannot index revision-spawned duplicates.
# @spec FACET-CONFIDENCE-020 @spec FACET-CONFIDENCE-023
RSpec.describe AddSourceRevisionToFacetConfidenceEvaluationGenerationIndex, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:index_name) { described_class::INDEX_NAME }
  let(:issue) { create(:issue) }

  include MigrationSpecHelpers

  around do |example|
    tables_existed = connection.table_exists?(:facet_confidence_evaluations)

    clear_evaluation_test_data
    example.run
  ensure
    clear_evaluation_test_data
    migration.up if tables_existed
    clear_schema_metadata!
  end

  it "keys one evaluation generation on issue, corpus digest, and source revision" do
    migration.up

    index = connection.indexes(:facet_confidence_evaluations).find { |candidate| candidate.name == index_name }
    expect(index.unique).to be(true)
    expect(index.columns).to eq(%w[issue_id corpus_digest source_revision])
    expect(index.nulls_not_distinct).to be(true)
  end

  it "rolls back to the legacy issue-and-digest generation key" do
    migration.up

    expect { migration.down }.not_to raise_error

    index = connection.indexes(:facet_confidence_evaluations).find { |candidate| candidate.name == index_name }
    expect(index.unique).to be(true)
    expect(index.columns).to eq(%w[issue_id corpus_digest])
  end

  it "refuses to roll back once one closeout holds multiple revision-spawned generations" do
    migration.up
    insert_evaluation(corpus_digest: "frozen-digest", source_revision: "rev-a")
    insert_evaluation(corpus_digest: "frozen-digest", source_revision: "rev-b")

    expect { migration.down }.to raise_error(
      ActiveRecord::IrreversibleMigration,
      /keep one evaluation per issue_id and corpus_digest/
    )
  end

  it "rolls back after distinct corpus generations exist for one closeout" do
    migration.up
    insert_evaluation(corpus_digest: "older-digest", source_revision: "rev-a")
    insert_evaluation(corpus_digest: "current-digest", source_revision: "rev-b")

    expect { migration.down }.not_to raise_error

    index = connection.indexes(:facet_confidence_evaluations).find { |candidate| candidate.name == index_name }
    expect(index.unique).to be(true)
    expect(index.columns).to eq(%w[issue_id corpus_digest])
  end

  private

  def insert_evaluation(corpus_digest:, source_revision:)
    # RLS is forced on this table even for its owner, so the raw insert runs
    # under the system-access context the app itself uses.
    TenantContext.with_system_access do
      connection.execute(<<~SQL.squish)
        INSERT INTO facet_confidence_evaluations (
          issue_id, project_id, created_by_id, corpus_digest, corpus_path,
          corpus_version, model_version, rubric_version, source_revision, status, created_at, updated_at
        ) VALUES (
          #{issue.id}, #{issue.project_id}, #{issue.project.created_by_id},
          #{connection.quote(corpus_digest)}, 'corpus/manifest.json',
          'v1', 'test-model', 'v1', #{connection.quote(source_revision)}, 'labeling',
          CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        )
      SQL
    end
  end

  # MigrationSpecHelpers#truncate_migration_test_data clears issues/projects
  # without first clearing the evaluation rows this spec inserts, which the
  # evaluations' foreign keys would reject; clear them first.
  def clear_evaluation_test_data
    delete_all_rows(:facet_confidence_evaluation_label_revisions)
    delete_all_rows(:facet_confidence_evaluation_labels)
    delete_all_rows(:facet_confidence_evaluations)
    truncate_migration_test_data
  end

  def delete_all_rows(table)
    connection.execute("DELETE FROM #{table}") if connection.table_exists?(table)
  end

  def clear_schema_metadata!
    connection.schema_cache.clear!
    connection.schema_cache.clear_data_source_cache!(:facet_confidence_evaluations)
    FacetConfidenceEvaluation.reset_column_information
  end
end
