# frozen_string_literal: true

class ProviderApiKeysController < ApplicationController
  before_action :set_provider_api_key, only: [ :show, :destroy ]
  skip_after_action :verify_authorized, only: :index

  def index
    @provider_api_keys = policy_scope(ProviderApiKey).ordered
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

  def destroy
    authorize @provider_api_key
    @provider_api_key.destroy!
    redirect_to provider_api_keys_path, notice: "API key deleted."
  end

  private

  def set_provider_api_key
    @provider_api_key = policy_scope(ProviderApiKey).find(params[:id])
  end

  def provider_api_key_params
    permitted = params.require(:provider_api_key).permit(:name, :api_key_ciphertext, compatible_providers: [])
    permitted[:compatible_providers] = Array(permitted[:compatible_providers]).reject(&:blank?)
    permitted
  end

  def load_provider_options
    @compatible_provider_options = ProviderSupport.supported_provider_keys.map do |key|
      [ key.titleize, key ]
    end
  end
end
