# frozen_string_literal: true

class LinearTokenPolicy < ApplicationPolicy
  def revoke?
    update?
  end
end
