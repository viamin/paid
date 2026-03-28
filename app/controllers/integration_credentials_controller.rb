# frozen_string_literal: true

class IntegrationCredentialsController < ApplicationController
  before_action :set_filter_context, only: [ :index, :new, :create ]
  before_action :set_integration_credential, only: [ :show, :destroy ]
  skip_after_action :verify_authorized, only: :index

  def index
    @integration_credentials = filtered_scope.order(created_at: :desc)
  end

  def show
    authorize @integration_credential
  end

  def new
    @integration_credential = current_account.integration_credentials.build(default_credential_attributes)
    authorize @integration_credential
    load_form_options
  end

  def create
    @integration_credential = current_account.integration_credentials.build(integration_credential_params)
    @integration_credential.created_by = current_user
    authorize @integration_credential
    load_form_options

    if @integration_credential.save
      redirect_to integration_credential_path(@integration_credential, return_filter_params), notice: "Credential saved."
    else
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    authorize @integration_credential
    @integration_credential.revoke!
    redirect_to integration_credentials_path(return_filter_params), notice: "Credential was successfully deactivated."
  end

  private

  def set_filter_context
    @category_filter = params[:category].presence || params.dig(:integration_credential, :category).presence
    @service_key_filter = params[:service_key].presence || params.dig(:integration_credential, :service_key).presence
    @service_definition = Integrations::CredentialCatalog.lookup(@service_key_filter)
  end

  def set_integration_credential
    @integration_credential = policy_scope(IntegrationCredential).find(params[:id])
  end

  def filtered_scope
    scope = policy_scope(IntegrationCredential)
    scope = scope.for_category(@category_filter) if @category_filter.present?
    scope = scope.for_service(@service_key_filter) if @service_key_filter.present?
    scope
  end

  def load_form_options
    service_key = @integration_credential.service_key.presence || @service_key_filter
    service_definition = Integrations::CredentialCatalog.lookup(service_key) if service_key.present?

    category = if service_definition && service_definition[:category].present?
      service_definition[:category]
    else
      @category_filter.presence || @integration_credential.category
    end

    @service_options = Integrations::CredentialCatalog.service_options_for(category: category)
    @auth_kind_options = Integrations::CredentialCatalog.auth_kind_options_for(service_key, category: category)
  end

  def default_credential_attributes
    defaults = {}
    defaults[:category] = @category_filter if @category_filter.present?
    defaults[:service_key] = @service_key_filter if @service_key_filter.present?
    defaults[:auth_kind] = @service_definition[:auth_kinds].first if @service_definition
    defaults
  end

  def integration_credential_params
    params.require(:integration_credential).permit(:name, :service_key, :category, :auth_kind, :secret, :expires_at)
  end

  # Derive category from the credential's saved state so the redirect
  # always matches the credential's actual category — even when the user
  # changed service_key to a service in a different category during the form.
  def return_filter_params
    filter_params = {}

    category_value = @integration_credential.category.presence || params[:category].presence
    filter_params[:category] = category_value if category_value.present?

    service_key_value = params[:service_key].presence
    filter_params[:service_key] = service_key_value if service_key_value.present?

    filter_params
  end
end
