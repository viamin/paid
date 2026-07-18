# frozen_string_literal: true

class PreviewTunnelPortReservation < ApplicationRecord
  validates :reservation_key, presence: true, uniqueness: true
  validates :tunnel_port, presence: true, uniqueness: true
end
