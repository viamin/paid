# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      default = [ [ nil ] ]
      user_id = request.session.fetch("warden.user.user.key", default)[0][0]
      if user_id && (user = User.find_by(id: user_id))
        user
      else
        reject_unauthorized_connection
      end
    end
  end
end
