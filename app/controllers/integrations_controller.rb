# frozen_string_literal: true

class IntegrationsController < ApplicationController
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def index
    @integration_sections = Integrations::Hub.sections_for(current_account)
  end
end
