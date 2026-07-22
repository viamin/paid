# frozen_string_literal: true

class PreviewTunnelReservation < ApplicationRecord
  validates :port,
    presence: true,
    numericality: { only_integer: true, greater_than: 0, less_than: 65_536 },
    uniqueness: true
end
