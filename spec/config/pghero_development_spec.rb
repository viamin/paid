# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "PgHero development integration" do
  # @spec RAILS-CONTROL-PLANE-016
  it "limits the database dashboard dependency and route to development" do
    root = File.expand_path("../..", __dir__)
    gemfile = File.read(File.join(root, "Gemfile"))
    routes = File.read(File.join(root, "config/routes.rb"))
    readme = File.read(File.join(root, "README.md"))
    development_group = gemfile[/group :development do(.*?)^end$/m, 1]

    expect(development_group).to include('gem "pghero", "~> 4.1"')
    expect(routes).to include('mount PgHero::Engine, at: "pghero" if Rails.env.development?')
    expect(readme).to include("bin/setup", "bin/dev", "http://localhost:3000/pghero", "DATABASE_URL")
  end

  # @spec RAILS-CONTROL-PLANE-016
  it "excludes PgHero from the production bundle" do
    root = File.expand_path("../..", __dir__)
    script = <<~RUBY
      require "bundler/setup"
      Bundler.require(:default, :production)
      abort "PgHero loaded" if defined?(PgHero)
    RUBY
    _stdout, stderr, status = Open3.capture3(
      { "RAILS_ENV" => "production" },
      "bundle", "exec", "ruby", "-e", script,
      chdir: root
    )

    expect(status.success?).to be(true), stderr
  end
end
