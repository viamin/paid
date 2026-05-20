# frozen_string_literal: true

class OperatorConsoleAccessController < ApplicationController
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def show
    authenticate_user!
    return if performed?

    redirect_to root_path, alert: "You are not authorized to access the operator console."
  end
end
