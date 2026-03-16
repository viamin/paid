# frozen_string_literal: true

class QualityDashboardsController < ApplicationController
  def show
    @stats = QualityMetrics::DashboardStats.call(account: current_account)
  end
end
