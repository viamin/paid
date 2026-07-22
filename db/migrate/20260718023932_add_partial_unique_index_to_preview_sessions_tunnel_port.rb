# frozen_string_literal: true

class AddPartialUniqueIndexToPreviewSessionsTunnelPort < ActiveRecord::Migration[8.1]
  # Defense-in-depth against concurrent preview starts that race on
  # {Previews::TunnelPortPool#acquire}. The pool serializes allocation with a
  # per-project advisory lock, but this index adds a hard backstop: two
  # transactions cannot persist the same `tunnel_port` to two live sessions
  # regardless of whether they respect the lock. The partial filter matches
  # the live-session definition (`status IN (...)`); the pool is responsible
  # for nulling `tunnel_port` on expired/terminal sessions before a port is
  # reclaimed, so expired-but-not-yet-reaped rows do not block new allocations.
  disable_ddl_transaction!

  def change
    add_index :preview_sessions, :tunnel_port,
      unique: true,
      where: "status IN ('pending', 'provisioning', 'starting', 'ready')",
      name: "index_preview_sessions_on_tunnel_port_active",
      algorithm: :concurrently
  end
end
