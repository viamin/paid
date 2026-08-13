# frozen_string_literal: true

class AddKnowledgeStatusToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :knowledge_status, :string, limit: 50, default: "pending", null: false
  end
end
