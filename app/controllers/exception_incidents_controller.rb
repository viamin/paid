# frozen_string_literal: true

class ExceptionIncidentsController < ApplicationController
  def index
    authorize ExceptionIncident

    scope = policy_scope(ExceptionIncident).recent
    scope = scope.filing_blocked if params[:filter] == "filing_blocked"

    @pagy, @exception_incidents = pagy(scope, limit: 25)
  end
end
