# frozen_string_literal: true

class PreviewProvisionState < ApplicationRecord
  belongs_to :agent_run

  validates :active_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
