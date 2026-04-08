# frozen_string_literal: true

class AddPriorityLabelsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :priority_labels, :jsonb, default: { "P1" => "P1", "P2" => "P2", "P3" => "P3" }, null: false
  end
end
