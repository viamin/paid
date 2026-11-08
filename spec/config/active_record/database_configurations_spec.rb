# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveRecord::DatabaseConfigurations, :no_db do # @spec RAILS-CONTROL-PLANE-010
  it "disables JIT on development connections without changing production" do
    configurations = ActiveRecord::Base.configurations
    development = configurations.configs_for(env_name: "development", name: "primary").configuration_hash
    cable = configurations.configs_for(env_name: "development", name: "cable").configuration_hash
    production = configurations.configs_for(env_name: "production", name: "primary").configuration_hash

    expect(development.fetch(:variables).fetch("jit")).to eq("off")
    expect(cable.fetch(:variables).fetch("jit")).to eq("off")
    expect(production.fetch(:variables, {})).not_to have_key("jit")
  end

  it "uses DATABASE_URL for database tasks instead of the local PostgreSQL socket" do
    skip "requires DATABASE_URL to pin database tasks" if ENV["DATABASE_URL"].blank?

    database_url = ENV.fetch("DATABASE_URL")
    development = ActiveRecord::Base.configurations.configs_for(env_name: "development", name: "primary").configuration_hash
    cable = ActiveRecord::Base.configurations.configs_for(env_name: "development", name: "cable").configuration_hash
    url = URI.parse(database_url)
    expected = {
      host: url.host,
      port: url.port,
      database: url.path.delete_prefix("/"),
      username: url.user,
      password: url.password
    }.compact

    expect(development).to include(expected)
    expect(cable).to include(host: url.host)
  end
end
