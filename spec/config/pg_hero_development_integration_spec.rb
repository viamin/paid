# frozen_string_literal: true

require "rails_helper"

class PgHeroDevelopmentIntegration
end

RSpec.describe PgHeroDevelopmentIntegration, :no_db do
  # @spec RAILS-CONTROL-PLANE-016
  it "keeps PgHero development-only and mounts it only in development" do
    gemfile = Rails.root.join("Gemfile").read
    routes = Rails.root.join("config/routes.rb").read

    expect(gemfile).to match(/group :development do.*gem "pghero", require: false/m)
    expect(routes).to include('mount PgHero::Engine, at: "pghero" if Rails.env.development? && defined?(PgHero::Engine)')
  end

  it "documents local PgHero startup, access, and database configuration" do
    readme = Rails.root.join("README.md").read

    expect(readme).to include("<http://localhost:3000/pghero>")
    expect(readme).to include("start Paid with `bin/dev`")
    expect(readme).to include("database configured by `DATABASE_URL`")
  end
end
