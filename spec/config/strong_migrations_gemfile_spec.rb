# frozen_string_literal: true

require "rails_helper"

class StrongMigrationsGemfile < Pathname
end

RSpec.describe StrongMigrationsGemfile, :no_db do
  subject(:gemfile_source) { Rails.root.join("Gemfile").read }

  it "keeps strong_migrations available outside development and test groups for migration safety_assured support" do
    strong_migrations_line = gemfile_source.lines.find { |line| line.include?('gem "strong_migrations"') }

    expect(strong_migrations_line).to be_present
    expect(strong_migrations_line).not_to match(/^\s{2,}gem "strong_migrations"/)
  end
end
