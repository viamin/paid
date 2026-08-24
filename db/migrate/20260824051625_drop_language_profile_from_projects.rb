# frozen_string_literal: true

class DropLanguageProfileFromProjects < ActiveRecord::Migration[8.1]
  def up
    # Compatibility release: older web/job processes still read
    # `projects.language_profile` during a normal migrate-before-restart
    # deploy, and a rollback needs the persisted value intact. Keep the
    # column until a later cleanup release can remove it safely.
  end

  def down
    # No-op: up intentionally preserves the legacy column for one more
    # compatibility release, so rollback has nothing to recreate.
  end
end
