class RemoveSecuritySeverityThresholdFromProjects < ActiveRecord::Migration[8.1]
  def change
    remove_column :projects, :security_severity_threshold, :string
  end
end
