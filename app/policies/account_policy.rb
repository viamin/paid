# frozen_string_literal: true

class AccountPolicy < ApplicationPolicy
  def show?
    user_in_account?
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_account_role?(:owner)
  end

  def manage_billing?
    has_account_role?(:owner)
  end

  # Flipper percentage gates are global (not tenant-scoped), so only the
  # account owner may modify them. In a future multi-tenant deployment,
  # consider scoping rollouts per-tenant or introducing a platform-admin role.
  def manage_feature_flags?
    has_account_role?(:owner)
  end

  private

  def user_in_account?
    user&.account_id == record.id
  end
end
