# frozen_string_literal: true

class ConfigurationBundle < ApplicationRecord
  has_many :agent_runs, dependent: :nullify
  has_many :configuration_bundle_outcomes, dependent: :destroy

  validates :fingerprint, presence: true, uniqueness: true, length: { maximum: 64 }
  validates :definition, presence: true
end
