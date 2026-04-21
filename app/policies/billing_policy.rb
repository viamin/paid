# frozen_string_literal: true

class BillingPolicy < ApplicationPolicy
  def billing?
    has_any_account_role?(:owner, :admin)
  end
end
