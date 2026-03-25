# frozen_string_literal: true

class ProjectVersion < ApplicationRecord
  belongs_to :project

  has_many :collector_runs, dependent: :destroy
  has_many :knowledge_artifacts, through: :collector_runs

  validates :commit_sha, presence: true, length: { maximum: 40 }
  validates :commit_sha, uniqueness: { scope: :project_id }
  validates :branch, presence: true

  scope :for_project, ->(project) { where(project: project) }
  scope :by_recency, -> { order(created_at: :desc) }
end
