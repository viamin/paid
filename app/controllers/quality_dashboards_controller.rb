# frozen_string_literal: true

class QualityDashboardsController < ApplicationController
  skip_after_action :verify_authorized

  def show
    @stats = QualityMetrics::DashboardStats.call(account: current_account)
  end
end
