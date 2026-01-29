# frozen_string_literal: true

class GithubTokenPolicy < ApplicationPolicy
  # Inherits from ApplicationPolicy:
  # - index?, show?: user_in_account?
  # - create?, new?: owner/admin/member
  # - update?, edit?: owner/admin
  # - destroy?: owner only
  #
  # GithubToken-specific permissions:
  # - revoke?: can deactivate tokens (same as update)

  def revoke?
    update?
  end
end
