# frozen_string_literal: true

module PgHeroDevelopmentRoutes
  # @spec RAILS-CONTROL-PLANE-016
  def self.draw(routes, environment: Rails.env)
    routes.mount PgHero::Engine, at: "/pghero" if environment.development?
  end
end
