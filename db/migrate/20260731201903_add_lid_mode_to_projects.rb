# frozen_string_literal: true

class AddLidModeToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    unless column_exists?(:projects, :lid_mode)
      add_column :projects, :lid_mode, :string,
        comment: "Effective Linked-Intent Development mode detected from the repository or forced in settings."
    end

    unless column_exists?(:projects, :lid_detection)
      add_column :projects, :lid_detection, :jsonb, default: {}, null: false,
        comment: "Repository-derived LID detection metadata such as version, sources, warnings, and detection time."
    end

    unless index_exists?(:projects, :lid_mode)
      add_index :projects, :lid_mode, algorithm: :concurrently
    end
  end
end
