# frozen_string_literal: true

require "rails_helper"
require "pghero"

class PgHeroDevelopmentIntegration < Pathname
end

RSpec.describe PgHeroDevelopmentIntegration, :no_db do
  # @spec RAILS-CONTROL-PLANE-016
  it "installs PgHero and mounts it only in development" do
    gemfile = Rails.root.join("Gemfile").read
    routes = Rails.root.join("config/routes.rb").read
    readme = Rails.root.join("README.md").read

    expect(PgHero::Engine).to be < Rails::Engine
    expect(gemfile).to match(/group :development do.*gem "pghero"/m)
    expect(routes).to include('PgHeroDevelopmentRoutes.draw(self)')
    expect(readme).to include("### PgHero (development only)", "bin/dev", "DATABASE_URL", "http://localhost:3000/pghero")
  end
end
