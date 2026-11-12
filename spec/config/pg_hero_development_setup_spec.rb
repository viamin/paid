# frozen_string_literal: true

require "rails_helper"

class PgHeroDevelopmentSetup < Pathname
end

RSpec.describe PgHeroDevelopmentSetup, :no_db do # @spec DEVELOPMENT-DATABASE-INSPECTION-001 # @spec DEVELOPMENT-DATABASE-INSPECTION-002
  it "keeps PgHero development-only and documents local startup and access" do
    gemfile = Rails.root.join("Gemfile").read
    routes = Rails.root.join("config/routes.rb").read
    readme = Rails.root.join("README.md").read

    expect(gemfile).to match(/group :development do.*gem "pghero"/m)
    expect(routes).to include("if Rails.env.development? && defined?(PgHero::Engine)", 'mount PgHero::Engine, at: "pghero"')
    expect(readme).to include("bin/setup", "bin/dev", "http://localhost:3000/pghero")
    expect(readme).to match(/No\s+PgHero-specific environment variable/)
  end
end
