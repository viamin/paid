# frozen_string_literal: true

class CreateProjectConventionDetections < ActiveRecord::Migration[8.1]
  def change
    create_table :project_convention_detections,
      comment: "Repository-derived convention detections captured for a specific project version." do |t|
      t.references :project, null: false, foreign_key: true, comment: "Project whose repository conventions were detected."
      t.string :key, null: false, comment: "Convention key detected from repository evidence."
      t.string :detector_key, null: false, comment: "Detector responsible for producing this normalized convention record."
      t.decimal :confidence, precision: 4, scale: 3, null: false, default: 1.0, comment: "Detector confidence from 0.0 to 1.0."
      t.jsonb :value, null: false, default: {}, comment: "Normalized detected convention payload."
      t.jsonb :evidence, null: false, default: {}, comment: "Structured supporting evidence with source files and matched signals."
      t.datetime :detected_at, null: false, comment: "Timestamp when the repository scan produced this detection."
      t.references :project_version, null: false, foreign_key: true, comment: "Project version whose tree was scanned."

      t.timestamps
    end

    add_index :project_convention_detections, [ :project_version_id, :key, :detector_key ],
      unique: true, name: "idx_project_convention_detections_unique_detector"
    add_index :project_convention_detections, [ :project_id, :key ]
  end
end
