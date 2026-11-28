# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-042
class RemoveRedundantRemediationAccountIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_remediation_decisions_on_account_id"
  COVERING_INDEX_NAME = "idx_remediation_decisions_budget_lookup"

  def up
    indexes = connection.indexes(:remediation_decisions)
    original = indexes.find { |index| index.name == INDEX_NAME }
    return unless original

    unless original.columns == [ "account_id" ] && !original.unique && original.where.nil?
      raise ActiveRecord::MigrationError, "Remediation account index no longer matches the nonunique prefix"
    end

    coverer = indexes.find { |index| index.name == COVERING_INDEX_NAME }
    unless coverer && coverer.valid? && coverer.where.nil? && coverer.using == :btree &&
        coverer.columns == %w[account_id diagnosis_attempted_on]
      raise ActiveRecord::MigrationError, "Remediation budget coverer must be a valid full btree index"
    end

    remove_index :remediation_decisions, name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    add_index :remediation_decisions, :account_id, name: INDEX_NAME,
      algorithm: :concurrently, if_not_exists: true
  end
end
