# frozen_string_literal: true

class RemoveDuplicateProjectConventionOverridesProjectIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  REDUNDANT_INDEX_NAME = "index_project_convention_overrides_on_project_id"
  COVERING_INDEX_NAME = "index_project_convention_overrides_on_project_id_and_key"

  # @spec POSTGRESQL-PERSISTENCE-014
  def up
    return unless index_exists?(:project_convention_overrides, name: REDUNDANT_INDEX_NAME)

    raise ActiveRecord::IrreversibleMigration, "#{COVERING_INDEX_NAME} must cover #{REDUNDANT_INDEX_NAME}" unless covering_index?

    remove_index :project_convention_overrides, name: REDUNDANT_INDEX_NAME, algorithm: :concurrently
  end

  def down
    return if index_exists?(:project_convention_overrides, name: REDUNDANT_INDEX_NAME)

    add_index :project_convention_overrides, :project_id,
      name: REDUNDANT_INDEX_NAME,
      algorithm: :concurrently
  end

  private

  def covering_index?
    index = connection.indexes(:project_convention_overrides).find { |candidate| candidate.name == COVERING_INDEX_NAME }

    index&.unique && index.columns == %w[project_id key]
  end
end
