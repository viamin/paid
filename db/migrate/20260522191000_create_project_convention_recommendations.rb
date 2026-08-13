# frozen_string_literal: true

class CreateProjectConventionRecommendations < ActiveRecord::Migration[8.1]
  def change
    create_table :project_convention_recommendations, comment: "Actionable convention-based recommendations for a project, with dismissal and audit tracking." do |t|
      t.references :project, null: false, foreign_key: true, comment: "The project this recommendation belongs to"
      t.string :convention_key, null: false, limit: 100, comment: "Convention key this recommendation relates to (e.g. commit_style, hook_manager)"
      t.string :action_type, null: false, limit: 50, comment: "Recommended action: apply_in_paid, open_pr, apply_github_side"
      t.string :status, null: false, default: "pending", limit: 30, comment: "Lifecycle: pending, applied, dismissed"
      t.string :title, null: false, limit: 255, comment: "Short human-readable recommendation title"
      t.text :description, null: false, comment: "Explanation of why the recommendation exists and what it does"
      t.jsonb :evidence, null: false, default: {}, comment: "Supporting evidence from detection that triggered this recommendation"
      t.string :dismissal_reason, comment: "User-provided reason for dismissal"
      t.datetime :dismissed_at, comment: "When the recommendation was dismissed"
      t.datetime :applied_at, comment: "When the recommendation was applied"
      t.references :dismissed_by, foreign_key: { to_table: :users }, comment: "User who dismissed the recommendation"
      t.references :applied_by, foreign_key: { to_table: :users }, comment: "User who applied the recommendation"
      t.datetime :generated_at, comment: "When the recommendation was generated from detection data"

      t.timestamps
    end

    add_index :project_convention_recommendations,
              %i[project_id convention_key action_type],
              name: "index_convention_recs_on_project_key_action",
              unique: true,
              where: "status = 'pending'"
    add_index :project_convention_recommendations,
              %i[project_id status],
              name: "index_convention_recs_on_project_status"
  end
end
