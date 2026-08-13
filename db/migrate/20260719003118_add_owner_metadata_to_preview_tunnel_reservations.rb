# frozen_string_literal: true

class AddOwnerMetadataToPreviewTunnelReservations < ActiveRecord::Migration[8.1]
  def change
    add_column :preview_tunnel_reservations, :owner_key, :string,
      comment: "Logical owner identifier for the process/session that reserved the preview tunnel port."
    add_column :preview_tunnel_reservations, :owner_pid, :integer,
      comment: "PID of the worker process that created the reservation so dead-worker leases can be reclaimed."
  end
end
