# frozen_string_literal: true

class RemoveRedundantTrustedMeasurementProjectIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-014
  def up
    remove_index :trusted_measurement_attempts,
      name: "index_trusted_measurement_attempts_on_project_id",
      algorithm: :concurrently
  end

  def down
    add_index :trusted_measurement_attempts,
      :project_id,
      name: "index_trusted_measurement_attempts_on_project_id",
      algorithm: :concurrently
  end
end
