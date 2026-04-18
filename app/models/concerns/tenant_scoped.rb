# frozen_string_literal: true

module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :account unless reflect_on_association(:account)

    scope :for_tenant, ->(account) { where(account_id: account.id) }
    scope :for_current_tenant, -> { Current.account ? where(account_id: Current.account.id) : none }
  end
end
