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

    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    return false unless visible?

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

      scope.joins(:prompt).where(prompts: { account_id: user.account_id })
            .or(scope.joins(:prompt).where(prompts: { account_id: nil }))
    end
  end
end
