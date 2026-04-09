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

  private

  def account_for_record
    record.is_a?(Class) ? user&.account : record.account
  end
end
