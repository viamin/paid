# frozen_string_literal: true

require "rails_helper"
require "pghero"
require Rails.root.join("config/routes/pghero_development_routes").to_s

RSpec.describe "PgHero development route", :no_db do
  # @spec RAILS-CONTROL-PLANE-016
  it "mounts PgHero for requests forwarded through Docker Compose" do
    routes = ActionDispatch::Routing::RouteSet.new
    environment = ActiveSupport::StringInquirer.new("development")
    routes.draw { PgHeroDevelopmentRoutes.draw(self, environment:) }
    routes.finalize!

    route = routes.routes.find { |candidate| candidate.app.app == PgHero::Engine }
    request = ActionDispatch::Request.new(
      Rack::MockRequest.env_for("/pghero", "REMOTE_ADDR" => "172.18.0.1")
    )

    expect(route).to be_present
    expect(route.matches?(request)).to be(true)
  end
end
