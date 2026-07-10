# frozen_string_literal: true

Rails.application.config.to_prepare do
  Previews::TunnelManager.configure!(
    port_range: ENV.fetch("PREVIEW_PORT_RANGE", Previews::TunnelManager::DEFAULT_PORT_RANGE),
    server_port: Integer(ENV.fetch("PREVIEW_TUNNEL_SERVER_PORT", Previews::TunnelManager::DEFAULT_SERVER_PORT)),
    server_bind_host: ENV.fetch("PREVIEW_TUNNEL_SERVER_BIND_HOST", Previews::TunnelManager::DEFAULT_SERVER_BIND_HOST),
    shared_token: Previews::TunnelManager.derived_shared_token
  )
end
