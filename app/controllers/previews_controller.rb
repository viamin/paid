# frozen_string_literal: true

class PreviewsController < ApplicationController
  require "net/http"

  COPYABLE_PROXY_RESPONSE_HEADERS = %w[
    cache-control
    content-language
    etag
    expires
    last-modified
    vary
  ].freeze

  # Missing/expired preview tokens return 404 before a project record exists to
  # authorize. Successful lookups still call `authorize @preview_session.project`.
  skip_after_action :verify_authorized, only: :show

  def show
    @preview_session = PreviewSession.active.live.find_by!(token: params[:token])
    authorize @preview_session.project

    apply_embed_headers
    @preview_session.touch_last_active!

    if simulated_session?
      render_simulated_preview
    else
      proxy_preview_request
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue Errno::ECONNREFUSED, SocketError, Net::ReadTimeout, EOFError => e
    render plain: "Preview is unavailable: #{e.message}", status: :bad_gateway
  end

  private

  def apply_embed_headers
    response.headers["Content-Security-Policy"] = "frame-ancestors 'self'"
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
  end

  def simulated_session?
    @preview_session.container_id.to_s.start_with?("preview-")
  end

  def render_simulated_preview
    render html: simulated_preview_markup.html_safe, layout: false
  end

  def simulated_preview_markup
    current_path = params[:path].to_s
    project_name = ERB::Util.html_escape(@preview_session.project.full_name)
    branch_name = ERB::Util.html_escape(@preview_session.branch_name)
    framework = ERB::Util.html_escape(@preview_session.framework.presence || "unknown")

    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Preview for #{project_name}</title>
          <style>
            :root { color-scheme: light; }
            body {
              margin: 0;
              font-family: ui-sans-serif, system-ui, sans-serif;
              background: linear-gradient(135deg, #f8fafc, #e2e8f0);
              color: #0f172a;
            }
            main { max-width: 56rem; margin: 0 auto; padding: 2rem; }
            .card {
              background: rgba(255, 255, 255, 0.9);
              border: 1px solid #cbd5e1;
              border-radius: 1rem;
              padding: 1.5rem;
              box-shadow: 0 12px 30px rgba(15, 23, 42, 0.08);
            }
            .meta {
              display: grid;
              gap: 0.75rem;
              grid-template-columns: repeat(auto-fit, minmax(12rem, 1fr));
              margin: 1.5rem 0;
            }
            code, a {
              color: #1d4ed8;
              font-weight: 600;
            }
          </style>
        </head>
        <body>
          <main>
            <div class="card">
              <p>Simulated preview</p>
              <h1>#{project_name}</h1>
              <p>This sandboxed iframe is live at <code>/previews/#{@preview_session.token}/</code> while the real container and reverse-proxy integration lands.</p>
              <div class="meta">
                <div><strong>Branch</strong><br><code>#{branch_name}</code></div>
                <div><strong>Framework</strong><br>#{framework}</div>
                <div><strong>Path</strong><br><code>/#{ERB::Util.html_escape(current_path)}</code></div>
                <div><strong>Tunnel Port</strong><br>#{@preview_session.tunnel_port || "pending"}</div>
              </div>
              <p><a href="#{preview_path(@preview_session.token, path: "health")}">Health endpoint</a></p>
            </div>
          </main>
        </body>
      </html>
    HTML
  end

  def proxy_preview_request
    upstream = preview_uri
    http = Net::HTTP.new(upstream.host, upstream.port)
    http.open_timeout = 2
    http.read_timeout = 5

    upstream_response = http.get(upstream.request_uri)
    response.status = upstream_response.code.to_i
    response.content_type = upstream_response.content_type if upstream_response.content_type.present?
    copy_proxy_headers(upstream_response)
    self.response_body = upstream_response.body
  end

  def preview_uri
    path = params[:path].to_s
    URI::HTTP.build(
      host: "127.0.0.1",
      port: @preview_session.tunnel_port,
      path: path.present? ? "/#{path}" : "/",
      query: request.query_string.presence
    )
  end

  def copy_proxy_headers(upstream_response)
    upstream_response.each_header do |key, value|
      next unless COPYABLE_PROXY_RESPONSE_HEADERS.include?(key)

      response.headers[key] = value
    end
  end
end
