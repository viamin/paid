# frozen_string_literal: true

class DashboardChannel < ApplicationCable::Channel
  def subscribed
    account = current_user.account
    stream_for account
  end
end
