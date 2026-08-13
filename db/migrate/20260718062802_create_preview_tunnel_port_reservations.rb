# frozen_string_literal: true

class CreatePreviewTunnelPortReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_tunnel_port_reservations, comment: "Shared preview tunnel port reservations across Rails processes" do |t|
      t.string :reservation_key, null: false, comment: "Stable preview session key that owns the reserved port"
      t.integer :tunnel_port, null: false, comment: "Host-side TCP port reserved for the preview tunnel"

      t.timestamps
    end

    add_index :preview_tunnel_port_reservations, :reservation_key, unique: true
    add_index :preview_tunnel_port_reservations, :tunnel_port, unique: true
  end
end
