# frozen_string_literal: true

class GithubInstallationPolicy < ApplicationPolicy
  def index?
    user.present?
  end
end
