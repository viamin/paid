# frozen_string_literal: true

class AddCheckConstraintToIssueDependencies < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :issue_dependencies,
                         "(depends_on_issue_id IS NOT NULL AND " \
                         "depends_on_owner IS NULL AND " \
                         "depends_on_repo IS NULL AND " \
                         "depends_on_number IS NULL) OR " \
                         "(depends_on_issue_id IS NULL AND " \
                         "NULLIF(depends_on_owner, '') IS NOT NULL AND " \
                         "NULLIF(depends_on_repo, '') IS NOT NULL AND " \
                         "depends_on_number > 0)",
                         name: "issue_dependencies_depends_on_xor"
  end
end
