# frozen_string_literal: true

class CollectorRun < ApplicationRecord
  belongs_to :project_version

  has_many :knowledge_artifacts, dependent: :destroy

  validates :collector_type, presence: true
  validates :status, presence: true
end
