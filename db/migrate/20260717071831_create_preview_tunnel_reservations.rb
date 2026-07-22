# frozen_string_literal: true

class CreatePreviewTunnelReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_tunnel_reservations,
      comment: "Tracks preview tunnel ports reserved across Ruby processes so concurrent preview boots cannot allocate the same port." do |t|
      t.integer :port, null: false, comment: "TCP port reserved for a preview tunnel listener on the control-plane host."
      t.timestamps
    end

    add_index :preview_tunnel_reservations, :port, unique: true
  end
end
