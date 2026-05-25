# frozen_string_literal: true

class AddOpenSourceToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :open_source, :boolean, default: false, null: false,
      comment: "Whether the project is open source (affects mutation test --usage flag)."
  end
end
