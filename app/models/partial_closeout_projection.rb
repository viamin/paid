# frozen_string_literal: true

class PartialCloseoutProjection < ApplicationRecord
  belongs_to :project
  has_many :entries, class_name: "PartialCloseoutProjectionEntry", foreign_key: :project_id,
    primary_key: :project_id, dependent: :delete_all, inverse_of: false

  validates :generation, presence: true, if: :computed_at?
end
