# frozen_string_literal: true

require "rails_helper"

RSpec.describe "development database tools", :no_db do
  let(:gemfile) { Rails.root.join("Gemfile").read }
  let(:routes) { Rails.root.join("config/routes.rb").read }
  let(:production_environment) { Rails.root.join("config/environments/production.rb").read }
  let(:readme) { Rails.root.join("README.md").read }

  # @spec DEV-DB-TOOLS-001
  it "makes PgHero available only from the local development route" do
    development_group = gemfile[/group :development do\n(?<contents>.*?)^end$/m, :contents]

    expect(development_group).to include('gem "pghero"')
    expect(routes).to include('mount PgHero::Engine, at: "pghero" if Rails.env.development? && defined?(PgHero)')
    expect(production_environment).not_to include("PgHero")
  end

  # @spec DEV-DB-TOOLS-002
  it "documents the local PgHero startup and access workflow" do
    expect(readme).to include("PgHero")
    expect(readme).to include("http://localhost:3000/pghero")
    expect(readme).to include("DATABASE_URL")
  end
end
