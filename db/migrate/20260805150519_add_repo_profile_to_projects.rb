# frozen_string_literal: true

class AddRepoProfileToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :repo_profile, :jsonb,
      default: {},
      null: false,
      comment: "Persisted repo-derived language/framework profile used by prompts, hooks, and preview/runtime consumers."
  end
end
