# frozen_string_literal: true

class DropPreviewTunnelReservations < ActiveRecord::Migration[8.1]
  def change
    drop_table :preview_tunnel_reservations, if_exists: true do |t|
      t.integer :port, null: false, comment: "TCP port reserved for a preview tunnel listener on the control-plane host."
      t.string :owner_key, comment: "Logical owner identifier for the process/session that reserved the preview tunnel port."
      t.integer :owner_pid, comment: "PID of the worker process that created the reservation so dead-worker leases can be reclaimed."
      t.timestamps

      t.index :port, unique: true
    end
  end
end
