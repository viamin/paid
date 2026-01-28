# frozen_string_literal: true

module Users
  class RegistrationsController < Devise::RegistrationsController
    before_action :configure_sign_up_params, only: [ :create ]

    def create
      build_resource(sign_up_params)

      account_name = params.dig(:user, :account_name)
      account = Account.new(name: account_name)
      resource.account = account

      ActiveRecord::Base.transaction do
        account.save!
        resource.save!

        yield resource if block_given?
        if resource.active_for_authentication?
          set_flash_message! :notice, :signed_up
          sign_up(resource_name, resource)
          respond_with resource, location: after_sign_up_path_for(resource)
        else
          set_flash_message! :notice, :"signed_up_but_#{resource.inactive_message}"
          expire_data_after_sign_in!
          respond_with resource, location: after_inactive_sign_up_path_for(resource)
        end
      end
    rescue ActiveRecord::RecordInvalid
      resource.errors.merge!(account.errors)
      clean_up_passwords resource
      set_minimum_password_length
      respond_with resource
    end

    protected

    def configure_sign_up_params
      devise_parameter_sanitizer.permit(:sign_up, keys: [ :name ])
    end
  end
end
