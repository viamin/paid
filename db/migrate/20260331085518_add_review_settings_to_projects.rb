# frozen_string_literal: true

class AddReviewSettingsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :review_settings, :jsonb, default: {}, null: false
  end
end
