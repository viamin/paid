# frozen_string_literal: true

class PartialCloseoutProjectionEntry < ApplicationRecord
  belongs_to :project
  belongs_to :issue

  validates :evidence_digest, :projection_generation, presence: true
end
