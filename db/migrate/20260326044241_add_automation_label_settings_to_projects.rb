# frozen_string_literal: true

class AddAutomationLabelSettingsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :generated_label_name, :string, default: "paid-generated", null: false
    add_column :projects, :automation_label_name, :string, default: "paid-automation", null: false
    add_column :projects, :auto_add_labels_enabled, :boolean, default: true, null: false
    add_column :projects, :automation_on_label_enabled, :boolean, default: true, null: false
  end
end
