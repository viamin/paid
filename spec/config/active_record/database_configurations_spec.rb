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
end
