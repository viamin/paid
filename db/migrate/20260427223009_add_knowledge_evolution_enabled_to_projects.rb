# frozen_string_literal: true

class AddKnowledgeEvolutionEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :knowledge_evolution_enabled, :boolean, default: false, null: false
  end
end
