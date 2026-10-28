# frozen_string_literal: true

class OpenrouterZdrRefresh < ApplicationRecord
  SOURCE = "openrouter_zdr".freeze
  STATUSES = %w[available unavailable].freeze

  validates :source, inclusion: { in: [ SOURCE ] }, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def self.current
    find_or_create_by!(source: SOURCE)
  end

  def mark_available!(at: Time.current)
    update!(status: "available", last_attempt_at: at, last_success_at: at, error_class: nil, error_message: nil)
  end

  def mark_unavailable!(error:, at: Time.current)
    update!(status: "unavailable", last_attempt_at: at, error_class: error.class.name, error_message: error.message)
  end
end
