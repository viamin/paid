# frozen_string_literal: true

require "spec_helper"

RSpec.describe "PgHero development integration" do
  # @spec RAILS-CONTROL-PLANE-016
  it "installs and mounts PgHero only for development" do
    root = File.expand_path("../..", __dir__)
    gemfile = File.read(File.join(root, "Gemfile"))
    routes = File.read(File.join(root, "config/routes.rb"))

    expect(gemfile).to include('gem "pghero"')
    expect(gemfile).to match(/group :development do[\s\S]*gem "pghero"/)
    expect(routes).to include('mount PgHero::Engine, at: "pghero" if Rails.env.development?')
  end
end
