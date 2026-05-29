# frozen_string_literal: true

module Api
  module ProjectInteropAuthentication
    extend ActiveSupport::Concern

    included do
      around_action :with_api_request_context
      before_action :set_project
    end

    private

    def with_api_request_context
      TenantContext.clear!
      Current.reset
      Current.request_id = request.uuid
      yield
    ensure
      TenantContext.clear!
      Current.reset
    end

    def set_project
      @project = TenantContext.with_system_access { Project.includes(:account).find(params[:project_id]) }
      TenantContext.apply!(@project.account)
      Current.account = @project.account
    rescue ActiveRecord::RecordNotFound
      render json: { errors: [ "Project not found" ] }, status: :not_found
    end

    def integration_credentials_for(service_key, auth_kinds: nil)
      return if service_key.blank?

      credentials = @project.account.integration_credentials
        .active
        .for_service(service_key)
        .order(created_at: :desc)

      return credentials if auth_kinds.blank?

      credentials.where(auth_kind: Array(auth_kinds).map(&:to_s))
    end

    def bearer_token
      request.authorization.to_s.delete_prefix("Bearer ").presence
    end

    def secure_token_match?(provided, expected)
      return false if provided.blank? || expected.blank?

      provided_digest = OpenSSL::Digest::SHA256.hexdigest(provided)
      expected_digest = OpenSSL::Digest::SHA256.hexdigest(expected)

      ActiveSupport::SecurityUtils.secure_compare(provided_digest, expected_digest)
    end
  end
end
