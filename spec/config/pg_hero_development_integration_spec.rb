# frozen_string_literal: true

require "rails_helper"
require "pghero"

class PgHeroDevelopmentIntegration < Pathname
end

RSpec.describe PgHeroDevelopmentIntegration, :no_db do
  around do |example|
    original_environment = PgHero.env
    PgHero.env = "development"
    reset_pghero_config
    example.run
  ensure
    PgHero.env = original_environment
    reset_pghero_config
  end

  # @spec RAILS-CONTROL-PLANE-018
  it "installs PgHero and mounts it only in development" do
    gemfile = Rails.root.join("Gemfile").read
    routes = Rails.root.join("config/routes.rb").read
    pg_hero_config = Rails.root.join("config/pghero.yml").read
    system_tests_workflow = Rails.root.join(".github/workflows/system_tests.yml").read
    readme = Rails.root.join("README.md").read

    expect(PgHero::Engine).to be < Rails::Engine
    expect(gemfile).to match(/group :development do.*gem "pghero"/m)
    expect(routes).to include('PgHeroDevelopmentRoutes.draw(self)')
    expect(pg_hero_config).to include('ENV.fetch("PGHERO_PASSWORD", Rails.application.secret_key_base)')
    expect(system_tests_workflow).to include('BUNDLE_WITHOUT: development')
    expect(readme).to include("### PgHero (development only)", "bin/dev", "DATABASE_URL", "PGHERO_PASSWORD", "http://localhost:3000/pghero")
  end

  # @spec RAILS-CONTROL-PLANE-018
  it "configures the primary Active Record database for PgHero" do
    expect(PgHero.databases.keys).to contain_exactly(:primary)
    expect(PgHero.databases.fetch(:primary).config).to include("spec" => "primary")
  end

  # @spec RAILS-CONTROL-PLANE-018
  it "binds the devcontainer web server to all interfaces so the forwarded port reaches Rails and PgHero" do
    devcontainer_compose = Rails.root.join(".devcontainer/compose.yaml").read

    expect(devcontainer_compose).to include('PAID_WEB_BIND_ADDRESS: "0.0.0.0"')
  end

  def reset_pghero_config
    %i[config databases file_config password username].each do |name|
      PgHero.remove_instance_variable(:"@#{name}") if PgHero.instance_variable_defined?(:"@#{name}")
    end
  end
end
