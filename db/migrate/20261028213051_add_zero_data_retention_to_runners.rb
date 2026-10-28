class AddZeroDataRetentionToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :zero_data_retention, :boolean, default: false, null: false,
      comment: "User-selected zero data retention requirement; enforcement provenance is derived from the active runner provider and runtime."
  end
end
