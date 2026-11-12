# frozen_string_literal: true

require "rails_helper"

class DevelopmentDatabaseTools < Pathname
end

RSpec.describe DevelopmentDatabaseTools, :no_db do
  # @spec DEVELOPMENT-DATABASE-TOOLS-001 DEVELOPMENT-DATABASE-TOOLS-002 DEVELOPMENT-DATABASE-TOOLS-003
  it "keeps PgHero development-only and documents its local access" do
    Bundler.require(:development)

    gemfile = Rails.root.join("Gemfile").read
    routes = Rails.root.join("config/routes.rb").read
    readme = Rails.root.join("README.md").read
    compose = Rails.root.join("docker-compose.yml").read

    development_group = gemfile[/group :development do\n(?<contents>.*?)\nend/m, :contents]

    expect(development_group).to include('gem "pghero"')
    expect(defined?(PgHero::Engine)).to eq("constant")
    expect(gemfile.scan('gem "pghero"')).to eq([ 'gem "pghero"' ])
    expect(routes).to include('mount PgHero::Engine, at: "pghero" if defined?(PgHero)')
    expect(compose).not_to include("pghero")
    expect(readme).to include("http://localhost:3000/pghero", "no additional environment variable")
  end
end
