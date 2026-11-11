# frozen_string_literal: true

class LinearTokenPolicy < ApplicationPolicy # @spec UNIFIED-WORK-ITEMS-002
  def create? = update?

  def destroy? = update?

  def revoke?
    update?
  end
end
