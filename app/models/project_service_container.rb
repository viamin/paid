# frozen_string_literal: true

class ProjectServiceContainer < ApplicationRecord
  belongs_to :project
  belongs_to :service_container

  validates :service_container_id, uniqueness: { scope: :project_id }
end
