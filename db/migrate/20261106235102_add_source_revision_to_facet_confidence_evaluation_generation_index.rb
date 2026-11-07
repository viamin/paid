# frozen_string_literal: true

# Keys a facet-confidence closeout evaluation generation on the closeout's
# recorded source revision as well as the frozen corpus digest, so a changed
# revision can start a new generation (the recovery route a stale
# reconciliation points to) instead of stranding the operator on a frozen row.
# Rolling back is only viable while no closeout holds multiple generations;
# down refuses rather than failing mid-rollback on the tighter legacy index.
# @spec FACET-CONFIDENCE-020 @spec FACET-CONFIDENCE-023
class AddSourceRevisionToFacetConfidenceEvaluationGenerationIndex < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_facet_confidence_evaluations_one_per_closeout_generation"
  GENERATION_COLUMNS = %i[issue_id corpus_digest source_revision].freeze
  LEGACY_GENERATION_COLUMNS = %i[issue_id corpus_digest].freeze
  INDEX_COMMENT = "Repeated Start/Resume actions reuse the same evaluation for the same evidence generation " \
    "(issue, corpus digest, source revision)."
  LEGACY_INDEX_COMMENT = "Repeated Start/Resume actions reuse the same evaluation for the same evidence generation."
  TABLE_COMMENT = "Facet-confidence closeout evaluation (#4596): one blinded reference-judgment session per " \
    "originating closeout (issue, frozen corpus digest, source revision) over the shipped RDR-070 corpus."
  LEGACY_TABLE_COMMENT = "Facet-confidence closeout evaluation (#4596): one blinded reference-judgment session per " \
    "originating closeout (issue, frozen corpus digest) over the shipped RDR-070 corpus."
  COLUMN_COMMENT = "Closeout source revision pinned at start; a changed revision starts a new evidence generation."
  LEGACY_COLUMN_COMMENT = "Closeout source revision recorded at start."

  disable_ddl_transaction!

  def up
    recreate_generation_index(GENERATION_COLUMNS, nulls_not_distinct: true, comment: INDEX_COMMENT)
    change_table_comment :facet_confidence_evaluations, from: LEGACY_TABLE_COMMENT, to: TABLE_COMMENT
    change_column_comment :facet_confidence_evaluations, :source_revision,
      from: LEGACY_COLUMN_COMMENT, to: COLUMN_COMMENT
  end

  def down
    assert_rollback_viable!

    change_column_comment :facet_confidence_evaluations, :source_revision,
      from: COLUMN_COMMENT, to: LEGACY_COLUMN_COMMENT
    change_table_comment :facet_confidence_evaluations, from: TABLE_COMMENT, to: LEGACY_TABLE_COMMENT
    recreate_generation_index(LEGACY_GENERATION_COLUMNS, nulls_not_distinct: false, comment: LEGACY_INDEX_COMMENT)
  end

  private

  # Must run before any down DDL: this migration is not transactional, so a
  # collision discovered while rebuilding the legacy index would leave the
  # schema half-rolled-back.
  def assert_rollback_viable!
    return unless duplicate_generations_exist?

    raise ActiveRecord::IrreversibleMigration,
      "Cannot restore the legacy one-per-(issue_id, corpus_digest) generation index while multiple " \
      "revision-aware evaluation generations exist for a closeout. Resolve the duplicates first " \
      "(keep one evaluation per issue_id and corpus_digest), then roll back."
  end

  def duplicate_generations_exist?
    # RLS is forced on this table even for the migrating role, so the duplicate
    # scan runs under a transaction-scoped tenant bypass.
    ActiveRecord::Base.transaction do
      safety_assured { execute("SET LOCAL paid.bypass_tenant_rls = 'true'") }
      select_value(<<~SQL.squish).present?
        SELECT 1
        FROM facet_confidence_evaluations
        GROUP BY issue_id, corpus_digest
        HAVING COUNT(*) > 1
        LIMIT 1
      SQL
    end
  end

  def recreate_generation_index(columns, nulls_not_distinct:, comment:)
    current = generation_index
    return if current && current.columns == columns.map(&:to_s) && current.nulls_not_distinct == nulls_not_distinct

    remove_index :facet_confidence_evaluations, name: INDEX_NAME, algorithm: :concurrently if current

    options = { unique: true, name: INDEX_NAME, comment:, algorithm: :concurrently }
    options[:nulls_not_distinct] = true if nulls_not_distinct
    add_index :facet_confidence_evaluations, columns, **options
  end

  def generation_index
    connection.indexes(:facet_confidence_evaluations).find { |index| index.name == INDEX_NAME }
  end
end
