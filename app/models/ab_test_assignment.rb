# frozen_string_literal: true

class AbTestAssignment < ApplicationRecord
  belongs_to :ab_test
  belongs_to :ab_test_variant
  belongs_to :agent_run

  validates :agent_run_id, uniqueness: true
end
