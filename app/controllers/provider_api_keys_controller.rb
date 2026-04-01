# frozen_string_literal: true

class ProviderApiKeysController < ApplicationController
  before_action :set_provider_api_key, only: [ :show, :edit, :update, :destroy ]
  skip_after_action :verify_authorized, only: :index

  def index
    @provider_api_keys = policy_scope(ProviderApiKey).includes(:providers).ordered
  end

  def show
    authorize @provider_api_key
  end

  def new
    @provider_api_key = current_user.provider_api_keys.build
    authorize @provider_api_key
    load_provider_options
  end

  def create
    @provider_api_key = current_user.provider_api_keys.build(provider_api_key_params)
    authorize @provider_api_key

    if @provider_api_key.save
      redirect_to provider_api_key_path(@provider_api_key),
        notice: "API key saved. You can now add API-key-based provider entries on the Providers page."
    else
      load_provider_options
      render :new, status: :unprocessable_content
    end
  end

  def edit
    authorize @provider_api_key
    load_provider_options
  end

  def update
    authorize @provider_api_key
    permitted = provider_api_key_params
    permitted.delete(:api_key) if permitted[:api_key].blank?
    if @provider_api_key.update(permitted)
      redirect_to provider_api_key_path(@provider_api_key),
        notice: "API key updated."
    else
      load_provider_options
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @provider_api_key
    if @provider_api_key.destroy
      redirect_to provider_api_keys_path, notice: "API key deleted."
    else
      redirect_to provider_api_key_path(@provider_api_key),
        alert: "Cannot delete this API key because it is used by provider entries. Remove those provider entries first."
    end
  end

  private

  def set_provider_api_key
    @provider_api_key = policy_scope(ProviderApiKey).find(params[:id])
  end

  def provider_api_key_params
    params.require(:provider_api_key).permit(:name, :api_key, :api_service_type)
  end

  def load_provider_options
    @api_service_type_options = ProviderApiKey.api_service_type_options
  end
end
