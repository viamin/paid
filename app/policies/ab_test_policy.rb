# frozen_string_literal: true

class AbTestPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    visible?
  end

  def create?
    has_any_account_role?(:owner, :admin)
  end

  def update?
    return false unless visible?
    # Global-prompt A/B tests are read-only to prevent cross-tenant mutation.
    return false if record.prompt&.account_id.nil?

    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    return false unless visible?
    # Global-prompt A/B tests are read-only to prevent cross-tenant mutation.
    return false if record.prompt&.account_id.nil?

    has_account_role?(:owner)
  end

  private

  def visible?
    return false unless user.present?
    return true if record.prompt&.account_id.nil?

    user_in_account?
  end

  def account_for_record
    # For new records (no prompt yet), fall back to the user's account
    # so that role checks work on the new/create actions.
    record.prompt&.account || user&.account
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      # Only show A/B tests for the user's own account. Global-prompt tests
      # are excluded from the scope to prevent cross-tenant data exposure.
      scope.joins(:prompt).where(prompts: { account_id: user.account_id })
    end
  end
end
