# frozen_string_literal: true

class AddAutoReleaseGranularityToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_release_granularity, :string, default: "off", null: false
  end
end
