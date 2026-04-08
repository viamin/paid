class AddPriorityLabelsToProjects < ActiveRecord::Migration[8.1]
  # Frozen snapshot of Project::DEFAULT_PRIORITY_LABELS at the time this
  # migration was authored. Migrations should not reference the live model
  # constant (which can change in the future), but if you change the
  # default in Project, audit existing rows so they stay consistent.
  DEFAULT_PRIORITY_LABELS = { "P1" => "P1", "P2" => "P2", "P3" => "P3" }.freeze

  def change
    add_column :projects, :priority_labels, :jsonb, default: DEFAULT_PRIORITY_LABELS, null: false
    add_column :projects, :inherit_priority_labels, :boolean, default: true, null: false
  end
end
