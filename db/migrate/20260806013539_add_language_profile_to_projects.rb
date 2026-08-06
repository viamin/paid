# frozen_string_literal: true

class AddLanguageProfileToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :language_profile, :jsonb, default: {}, null: false,
      comment: "Persisted repo-derived language/framework profile. Drives polyglot test/lint command routing (e.g. { \"languages\": [...], \"test_languages\": [...] }). Populated by detection (#3207) and optional .paid.yml manifest."
  end
end
