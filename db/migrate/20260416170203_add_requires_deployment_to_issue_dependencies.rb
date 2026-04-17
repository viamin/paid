# frozen_string_literal: true

# Flags a dependency as blocking until the target has been deployed, not
# merely merged/closed. Defaults to false so all existing dependency
# semantics are preserved. Parsed from body/comment phrases like
# "Awaits deployment of #N" or "Blocked by deployment of #N".
class AddRequiresDeploymentToIssueDependencies < ActiveRecord::Migration[8.1]
  def change
    add_column :issue_dependencies, :requires_deployment, :boolean,
               default: false, null: false
  end
end
