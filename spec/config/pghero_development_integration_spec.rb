# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PgHero development integration", :no_db do # @spec RAILS-CONTROL-PLANE-016
  let(:gemfile) { Rails.root.join("Gemfile").read }
  let(:routes) { Rails.root.join("config/routes.rb").read }
  let(:readme) { Rails.root.join("README.md").read }

  it "installs and mounts PgHero only for local development" do
    development_group = gemfile[/group :development do(?<contents>.*?)^end$/m, :contents]

    expect(development_group).to include('gem "pghero"')
    expect(routes).to include('mount PgHero::Engine, at: "pghero" if defined?(PgHero)')
  end

  it "documents startup, access, and the database connection PgHero inspects" do
    expect(readme).to include("bin/setup")
    expect(readme).to include("bin/dev")
    expect(readme).to include("http://localhost:3000/pghero")
    expect(readme).to include("DATABASE_URL")
  end
end
