# frozen_string_literal: true

require "rails_helper"

class DropLanguageProfileFromProjectsMigrationFile < Pathname
end

RSpec.describe DropLanguageProfileFromProjectsMigrationFile, :no_db do
  subject(:migration_source) do
    Rails.root.join("db/migrate/20260824051625_drop_language_profile_from_projects.rb").read
  end

  it "keeps the legacy column in place for a compatibility release", :aggregate_failures do
    expect(migration_source).not_to include("remove_column :projects, :language_profile")
    expect(migration_source).to include("older web/job processes still read")
    expect(migration_source).to include("rollback needs the persisted value intact")
  end
end
