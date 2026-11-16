# frozen_string_literal: true

class PartialCloseoutProjection < ApplicationRecord
  belongs_to :project
  has_many :entries, class_name: "PartialCloseoutProjectionEntry", dependent: :delete_all

  validates :generation, presence: true, if: :computed_at?
end
