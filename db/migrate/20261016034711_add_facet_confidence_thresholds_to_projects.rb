# frozen_string_literal: true

class AddFacetConfidenceThresholdsToProjects < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:projects, :intent_threshold)
      add_column :projects, :intent_threshold, :integer, null: false, default: 80,
        comment: "Minimum intent certainty (0-100) for each mapped facet prerequisite."
    end
    unless column_exists?(:projects, :technical_threshold)
      add_column :projects, :technical_threshold, :integer, null: false, default: 80,
        comment: "Minimum technical confidence (0-100) for each mapped facet prerequisite."
    end
    unless check_constraint_exists?(:projects, name: "projects_intent_threshold_bounds")
      add_check_constraint :projects, "intent_threshold BETWEEN 0 AND 100", name: "projects_intent_threshold_bounds", validate: false
    end
    unless check_constraint_exists?(:projects, name: "projects_technical_threshold_bounds")
      add_check_constraint :projects, "technical_threshold BETWEEN 0 AND 100", name: "projects_technical_threshold_bounds", validate: false
    end
  end

  def down
    remove_check_constraint :projects, name: "projects_intent_threshold_bounds" if check_constraint_exists?(:projects, name: "projects_intent_threshold_bounds")
    remove_check_constraint :projects, name: "projects_technical_threshold_bounds" if check_constraint_exists?(:projects, name: "projects_technical_threshold_bounds")
    remove_column :projects, :intent_threshold if column_exists?(:projects, :intent_threshold)
    remove_column :projects, :technical_threshold if column_exists?(:projects, :technical_threshold)
  end
end
