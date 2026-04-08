# frozen_string_literal: true

class AddPriorityLabelsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :priority_labels, :jsonb, default: {}, null: false
    add_index :issues, [ :project_id, :github_number ], name: "index_issues_on_project_id_and_github_number"
  end
end
