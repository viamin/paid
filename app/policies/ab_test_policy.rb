# frozen_string_literal: true

class AbTestPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    user_in_account?
  end

  def create?
    has_any_account_role?(:owner, :admin)
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_account_role?(:owner)
  end

  private

  def account_for_record
    record.prompt&.account
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.joins(:prompt).where(prompts: { account_id: user.account_id })
            .or(scope.joins(:prompt).where(prompts: { account_id: nil }))
    end
  end
end
