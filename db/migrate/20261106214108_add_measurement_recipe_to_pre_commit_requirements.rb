class AddMeasurementRecipeToPreCommitRequirements < ActiveRecord::Migration[8.1]
  def change
    add_column :pre_commit_requirements, :measurement_recipe, :jsonb
  end
end
