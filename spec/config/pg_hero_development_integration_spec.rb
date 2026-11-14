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
    readme = Rails.root.join("README.md").read

    expect(PgHero::Engine).to be < Rails::Engine
    expect(gemfile).to match(/group :development do.*gem "pghero"/m)
    expect(routes).to include('PgHeroDevelopmentRoutes.draw(self)')
    expect(pg_hero_config).not_to include("password:")
    expect(readme).to include("### PgHero (development only)", "bin/dev", "DATABASE_URL", "PGHERO_PASSWORD", "http://localhost:3000/pghero")
  end

  # @spec RAILS-CONTROL-PLANE-018
  it "configures the primary Active Record database for PgHero" do
    expect(PgHero.databases.keys).to contain_exactly(:primary)
    expect(PgHero.databases.fetch(:primary).config).to include("spec" => "primary")
    expect(PgHero.databases.fetch(:primary).slow_query_ms).to eq(100)
    expect(PgHero.databases.fetch(:primary).slow_query_calls).to eq(5)
    expect(PgHero.kill_enabled?).to be(false)
    expect(PgHero.explain_enabled?).to be(false)
    expect(PgHero.databases.fetch(:primary).filter_data).to be(true)
  end

  # @spec RAILS-CONTROL-PLANE-018
  it "binds the devcontainer web server to all interfaces so the forwarded port reaches Rails and PgHero" do
    devcontainer_compose = Rails.root.join(".devcontainer/compose.yaml").read

    expect(devcontainer_compose).to include('PAID_WEB_BIND_ADDRESS: "0.0.0.0"')
  end

  # @spec RAILS-CONTROL-PLANE-018
  it "enables current query stats in both development PostgreSQL setups" do
    devcontainer_compose = Rails.root.join(".devcontainer/compose.yaml").read
    docker_compose = Rails.root.join("docker-compose.yml").read
    postgres_init = Rails.root.join("docker/postgres/init-multiple-dbs.sh").read

    expect(devcontainer_compose).to include("shared_preload_libraries=pg_stat_statements")
    expect(docker_compose).to include("shared_preload_libraries=pg_stat_statements")
    expect(postgres_init).to include('CREATE EXTENSION IF NOT EXISTS pg_stat_statements')
    expect(devcontainer_compose).to include('PAID_ENABLE_DEV_QUERY_STATS: "1"')
    expect(docker_compose).to include('PAID_ENABLE_DEV_QUERY_STATS: "1"')
  end

  def reset_pghero_config
    %i[config databases file_config password username].each do |name|
      PgHero.remove_instance_variable(:"@#{name}") if PgHero.instance_variable_defined?(:"@#{name}")
    end
  end
end
