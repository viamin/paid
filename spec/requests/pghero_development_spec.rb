# frozen_string_literal: true

require "rails_helper"
require "pghero"
require Rails.root.join("config/routes/pghero_development_routes").to_s

RSpec.describe "PgHero development route", :no_db do
  around do |example|
    original_password = ENV.fetch("PGHERO_PASSWORD", nil)
    original_environment = PgHero.env
    ENV["PGHERO_PASSWORD"] = "development-password"
    PgHero.env = "development"
    reset_pghero_auth_config
    example.run
  ensure
    ENV["PGHERO_PASSWORD"] = original_password
    ENV.delete("PGHERO_PASSWORD") unless original_password
    PgHero.env = original_environment
    reset_pghero_auth_config
  end

  # @spec RAILS-CONTROL-PLANE-018
  it "configures authentication for requests forwarded through Docker Compose" do
    routes = ActionDispatch::Routing::RouteSet.new
    environment = ActiveSupport::StringInquirer.new("development")
    routes.draw { PgHeroDevelopmentRoutes.draw(self, environment:) }
    routes.finalize!

    route = routes.routes.find { |candidate| candidate.app.app == PgHero::Engine }
    expect(route).to be_present
    expect(PgHero.password).to eq("development-password")
  end

  def reset_pghero_auth_config
    pghero_config_variables.each do |name|
      PgHero.remove_instance_variable(:"@#{name}") if PgHero.instance_variable_defined?(:"@#{name}")
    end
  end

  def pghero_config_variables
    %i[file_config password username]
  end
end
