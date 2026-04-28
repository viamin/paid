# frozen_string_literal: true

class CreateKnowledgeRecommendations < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_recommendations do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.string :recommendation_type, null: false, limit: 50
      t.string :collector_type, limit: 100
      t.string :priority, default: "medium", null: false, limit: 20
      t.text :description
      t.jsonb :evidence, default: {}, null: false
      t.string :status, default: "pending", null: false, limit: 20
      t.datetime :dismissed_at
      t.text :dismissal_reason
      t.timestamps
    end

    add_index :knowledge_recommendations, [ :project_id, :status ]
    add_index :knowledge_recommendations, [ :project_id, :recommendation_type ]
  end
end
