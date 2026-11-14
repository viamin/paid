# frozen_string_literal: true

module PgHeroDevelopmentRoutes
  # @spec RAILS-CONTROL-PLANE-018
  def self.draw(routes, environment: Rails.env)
    return unless environment.development?

    routes.match "/pghero(/*path)",
      to: ->(_environment) { [ 405, { "allow" => "GET, HEAD", "content-type" => "text/plain" }, [ "Method Not Allowed" ] ] },
      via: %i[post put patch delete]
    routes.mount PgHero::Engine, at: "/pghero"
  end
end
