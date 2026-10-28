class AddZdrToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :zdr, :boolean, default: false, null: false,
      comment: "Runner-level zero data retention declaration; provider provenance is derived at read time."
  end
end
