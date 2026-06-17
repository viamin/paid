# frozen_string_literal: true

class ExceptionIncidentPolicy < ApplicationPolicy
  private

  def account_for_record
    record.is_a?(Class) ? user&.account : record.account
  end
end
