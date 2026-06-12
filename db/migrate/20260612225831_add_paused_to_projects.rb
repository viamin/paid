# frozen_string_literal: true

class AddPausedToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :paused, :boolean, null: false, default: false,
      comment: "When true, queued automatic agent runs for this project will not be started. Manual runs are unaffected."
  end
end
