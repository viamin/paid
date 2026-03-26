# frozen_string_literal: true

class ProjectVersion < ApplicationRecord
  belongs_to :project

  has_many :collector_runs, dependent: :destroy

  validates :commit_sha, presence: true, length: { maximum: 40 }
  validates :branch, presence: true
  validates :commit_sha, uniqueness: { scope: :project_id }
end
