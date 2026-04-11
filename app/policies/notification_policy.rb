# frozen_string_literal: true

class NotificationPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def read?
    user_in_account?
  end

  def dismiss?
    user_in_account?
  end

  def mark_all_read?
    user_in_account?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(account: user.account, user_id: nil).or(
        scope.where(account: user.account, user_id: user.id)
      )
    end
  end

  private

  def account_for_record
    record.is_a?(Class) ? user&.account : record.account
  end
end
