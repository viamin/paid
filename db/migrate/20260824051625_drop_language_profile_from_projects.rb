# frozen_string_literal: true

class DropLanguageProfileFromProjects < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:projects, :language_profile)

    remove_column :projects, :language_profile
  end

  def down
    return if column_exists?(:projects, :language_profile)

    add_column :projects, :language_profile, :jsonb, default: {}, null: false,
      comment: "Deprecated duplicate repo profile column retained only for rollback."
  end
end
