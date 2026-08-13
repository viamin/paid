# frozen_string_literal: true

class DropOpenSourceFromProjects < ActiveRecord::Migration[8.1]
  def change
    safety_assured { remove_column :projects, :open_source, :boolean, default: false, null: false }
  end
end
