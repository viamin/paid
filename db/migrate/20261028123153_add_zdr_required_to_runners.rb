class AddZdrRequiredToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :zdr_required, :boolean, default: false, null: false,
      comment: "Whether this runner requires zero data retention for provider inference"
  end
end
