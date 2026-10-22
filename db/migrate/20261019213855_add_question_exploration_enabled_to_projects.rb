# frozen_string_literal: true

class AddQuestionExplorationEnabledToProjects < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:projects, :question_exploration_enabled)

    add_column :projects, :question_exploration_enabled, :boolean, default: false, null: false,
      comment: "RDR-069 rollout gate for question-centered exploration conversations; initially disabled for every project."
  end

  def down
    return unless column_exists?(:projects, :question_exploration_enabled)

    remove_column :projects, :question_exploration_enabled
  end
end
