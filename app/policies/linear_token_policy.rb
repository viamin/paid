# frozen_string_literal: true

class LinearTokenPolicy < ApplicationPolicy
  def create? = update?

  def destroy? = update?

  def revoke?
    update?
  end
end
