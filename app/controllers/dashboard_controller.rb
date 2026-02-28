# frozen_string_literal: true

class DashboardController < ApplicationController
  before_action :authenticate_user!

  def show
    @stats = Dashboard::Stats.call(account: current_account)
  end
end
