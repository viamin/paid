# frozen_string_literal: true

module Api
  # Materializes selected runner auth for a short-lived text executor.
  class StandaloneTextCredentialsController < ActionController::API
    around_action :with_tenant_context
    before_action :authenticate_identity!

    def show # @spec LLM-ROUTING-003 LLM-ROUTING-005 LLM-ROUTING-006
      response.set_header("Cache-Control", "no-store")
      return render_api_key if runner.api_key?

      render_subscription
    end

    private

    attr_reader :account, :identity, :runner

    def render_api_key
      secret = runner.effective_api_secret
      return render json: { error: "API credential is unavailable" }, status: :service_unavailable if secret.blank?

      render json: { env: identity.fetch(:env_keys, []).index_with { secret }, files: {} }
    end

    def render_subscription
      credential = account.runner_credentials.active.for_runner(runner.runner_key)
        .order(created_at: :desc, id: :desc).first
      return render json: { error: "Managed subscription credential is unavailable" }, status: :service_unavailable unless credential

      materialization = Runners::SubscriptionAuthProviders.for_runner(runner.runner_key)&.materialize(secret: credential.token)
      return render json: { error: "Managed subscription credential cannot be materialized" }, status: :unprocessable_entity unless materialization&.supported?

      credential.update_column(:last_used_at, Time.current)
      render json: { env: materialization.env, files: materialization.files }
    end

    def with_tenant_context
      previous_account = Current.account
      previous_bypass = TenantContext.bypass_enabled?
      TenantContext.clear!
      yield
    ensure
      TenantContext.restore!(account: previous_account, bypass: previous_bypass)
    end

    def authenticate_identity!
      @identity = Containers::StandaloneTextCredential.verify(bearer_token)
      return reject_identity unless identity

      TenantContext.with_system_access do
        @account = Account.find_by(id: identity[:account_id])
        @runner = Runner.joins(:user)
          .find_by(id: identity[:runner_id], users: { account_id: @account&.id })
      end
      return reject_identity unless @account && @runner

      TenantContext.apply!(@account)
    end

    def bearer_token
      request.authorization.to_s.delete_prefix("Bearer ").presence
    end

    def reject_identity
      render json: { error: "Invalid standalone text credential" }, status: :forbidden
    end
  end
end
