# frozen_string_literal: true

class ValidateCurrentVersionFkOnStyleGuides < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :style_guides, :style_guide_versions, column: :current_version_id
  end
end
