# frozen_string_literal: true

class UserSettingPolicy < ApplicationPolicy
  def edit?
    owner?
  end

  def update?
    owner?
  end

  private

  def owner?
    user && record.user_id == user.id
  end
end
