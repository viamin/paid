# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    # Cookie read by the connection to authorize the websocket. ActionCable
    # serves connections from Rails.application.env_config, which carries the
    # cookie-jar configuration but NOT the Warden/session middleware (env_config
    # has neither "warden" nor "rack.session"). So request.env["warden"] is
    # always nil here and request.session is empty — the connection cannot use
    # Devise's warden proxy to identify the subscriber. ApplicationController
    # stamps this encrypted cookie on every authenticated request instead.
    CABLE_USER_COOKIE = :cable_user_id

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      user = request.env["warden"]&.user || user_from_cable_cookie
      user || reject_unauthorized_connection
    end

    def user_from_cable_cookie
      user_id = cookies.encrypted[CABLE_USER_COOKIE]
      return unless user_id

      # The connection runs outside ApplicationController, so no tenant context
      # is set and the RLS-scoped users table hides every row. Bypass RLS to
      # resolve the user the encrypted cookie identifies; channel actions
      # establish their own tenant context for the actual work.
      TenantContext.with_system_access { User.find_by(id: user_id) }
    end
  end
end
