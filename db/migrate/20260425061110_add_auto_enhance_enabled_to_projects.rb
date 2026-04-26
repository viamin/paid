# frozen_string_literal: true

class AddAutoEnhanceEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_enhance_enabled, :boolean, default: false, null: false
  end
end
