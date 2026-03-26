# frozen_string_literal: true

class IntegrationsController < ApplicationController
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def index
    @providers_by_category = Integrations::Registry.by_category
    @token_counts = build_token_counts
  end

  private

  def build_token_counts
    Integrations::Registry.providers.each_with_object({}) do |provider, counts|
      counts[provider.key] = provider.token_count(current_account)
    end
  end
end
