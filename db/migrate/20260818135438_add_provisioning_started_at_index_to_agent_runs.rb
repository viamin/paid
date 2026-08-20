# frozen_string_literal: true

class AddProvisioningStartedAtIndexToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_agent_runs_on_provisioning_started_at".freeze
  COLUMN_NAME = :provisioning_started_at
  INDEX_WHERE = "provisioning_started_at IS NOT NULL".freeze

  def up
    unless column_exists?(:agent_runs, COLUMN_NAME)
      add_column :agent_runs, COLUMN_NAME, :timestamptz,
        comment: "When queue admission started provisioning this attempt for provisioning-rate enforcement."
    end

    backfill_provisioning_started_at!
    return if index_exists?(:agent_runs, COLUMN_NAME, name: INDEX_NAME)

    add_index :agent_runs,
      COLUMN_NAME,
      name: INDEX_NAME,
      where: INDEX_WHERE,
      algorithm: :concurrently
  end

  def down
    remove_index :agent_runs, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
    remove_column :agent_runs, COLUMN_NAME if column_exists?(:agent_runs, COLUMN_NAME)
  end

  private

  def backfill_provisioning_started_at!
    safety_assured do
      execute <<~SQL.squish
        UPDATE agent_runs
        SET provisioning_started_at = NULLIF(external_metadata ->> 'provisioning_started_at', '')::timestamptz
        WHERE provisioning_started_at IS NULL
          AND COALESCE(external_metadata ->> 'provisioning_started_at', '') != ''
      SQL
    end
  end
end
