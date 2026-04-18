# frozen_string_literal: true

class ReplaceAutoMergeBooleansWithAutoMergeMode < ActiveRecord::Migration[8.1]
  def up
    add_column :projects, :auto_merge_mode, :string, default: "off", null: false

    Project.reset_column_information
    Project.find_each do |p|
      mode = if p[:auto_merge_enabled] && p[:auto_merge_dependabot]
        "all"
      elsif p[:auto_merge_dependabot]
        "dependabot_only"
      elsif p[:auto_merge_enabled]
        "all"
      else
        "off"
      end
      Project.where(id: p.id).update_all(auto_merge_mode: mode)
    end

    remove_column :projects, :auto_merge_enabled
    remove_column :projects, :auto_merge_dependabot
  end

  def down
    add_column :projects, :auto_merge_enabled, :boolean, default: false, null: false
    add_column :projects, :auto_merge_dependabot, :boolean, default: false, null: false

    Project.reset_column_information
    Project.find_each do |p|
      enabled = p.auto_merge_mode != "off"
      dependabot = p.auto_merge_mode.in?(%w[dependabot_only all])
      Project.where(id: p.id).update_all(
        auto_merge_enabled: enabled,
        auto_merge_dependabot: dependabot
      )
    end

    remove_column :projects, :auto_merge_mode
  end
end
