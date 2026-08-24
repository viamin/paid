# frozen_string_literal: true

class DropLanguageProfileFromProjects < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:projects, :language_profile)

    # All application references to `language_profile` were removed in this
    # PR (see RDR-046 follow-up), so there is no attribute-caching hazard
    # from a mid-deploy old-code/new-schema mismatch.
    safety_assured { remove_column :projects, :language_profile }
  end

  def down
    return if column_exists?(:projects, :language_profile)

    add_column :projects, :language_profile, :jsonb, default: {}, null: false,
      comment: "Deprecated duplicate repo profile column retained only for rollback."
  end
end
