# frozen_string_literal: true

class AddCurrentVersionFkToStyleGuides < ActiveRecord::Migration[8.1]
  def change
    # Guard with if_not_exists so fresh setups (where the FK was already created
    # by 20260709225313_create_style_guide_evolution_pipeline) skip this safely.
    # validate: false avoids a blocking table scan on existing rows (strong_migrations requirement).
    add_foreign_key :style_guides, :style_guide_versions, column: :current_version_id,
      on_delete: :nullify, if_not_exists: true, validate: false
  end
end
