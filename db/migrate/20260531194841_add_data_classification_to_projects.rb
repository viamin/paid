# frozen_string_literal: true

class AddDataClassificationToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :data_classification, :string, default: "internal", null: false,
      comment: "Sensitivity level for project data shared with model providers."
  end
end
