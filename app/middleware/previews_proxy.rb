# frozen_string_literal: true

require "net/http"
require "socket"
require "timeout"

# Rack reverse proxy that exposes a tunnelled web app at `/previews/:token/*`.
#
# The middleware validates the preview token against an active {PreviewSession},
# resolves the localhost tunnel port the rathole client bridged the container's
# app to, and forwards the request. It strips iframe-blocking headers
# (`X-Frame-Options`, CSP `frame-ancestors`), rewrites redirect `Location` and
# `Set-Cookie` scoping so traffic stays within the proxy origin, and handles
# WebSocket upgrades (`101 Switching Protocols`) via full Rack socket hijack so
# Phoenix LiveView and Rails Action Cable connections pass through transparently.
#
# Loaded eagerly via `require_relative` in `config/application.rb` because the
# middleware constant must exist at middleware-registration time, before Zeitwerk
# autoloading is available (see the QueryMonitor precedent in the same file).
class PreviewsProxy
  # Matches `/previews/:token/<path>` where <path> is any non-empty segment,
  # including the bare root `/`. The exact `/previews/:token` (no trailing path)
  # intentionally does NOT match — that is served by PreviewsController#show.
  PATH_PATTERN = %r{\A/previews/([^/]+)(/.*)\z}.freeze

  # Hop-by-hop headers per RFC 7230 §6.1 — never forwarded verbatim on HTTP.
  # (WebSocket upgrades forward Connection/Upgrade via the raw request path.)
  HOP_BY_HOP_HEADERS = %w[
    connection
    keep-alive
    proxy-authenticate
    proxy-authorization
    te
    trailers
    transfer-encoding
    upgrade
  ].freeze

  REQUEST_CLASSES = {
    "GET" => Net::HTTP::Get,
    "HEAD" => Net::HTTP::Head,
    "POST" => Net::HTTP::Post,
    "PUT" => Net::HTTP::Put,
    "PATCH" => Net::HTTP::Patch,
    "DELETE" => Net::HTTP::Delete,
    "OPTIONS" => Net::HTTP::Options
  }.freeze

  BUFFER_SIZE = 16_384
  DEFAULT_READ_TIMEOUT = 300
  DEFAULT_OPEN_TIMEOUT = 10
  CONNECT_HOST = "127.0.0.1"

  def initialize(app, read_timeout: DEFAULT_READ_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT)
    @app = app
    @read_timeout = read_timeout
    @open_timeout = open_timeout
  end

  def call(env)
    match = PATH_PATTERN.match(env[Rack::PATH_INFO])
    # Delegation to the downstream app must NOT be wrapped in a rescue: Rails
    # relies on exceptions (e.g. RecordNotFound) propagating to its own
    # exception-handling middleware to render 404/500 responses.
    return @app.call(env) unless match

    serve_preview_safely(env, match:)
  end

  def serve_preview_safely(env, match:)
    serve_preview(env, match:)
  rescue StandardError => e
    log_error("previews_proxy.request_failed", token: match[1], error: e.message)
    error_response
  end

  def serve_preview(env, match:)
    token = match[1]
    proxied_path = match[2]

    session = resolve_session(token)
    return not_found unless session&.proxiable?

    request = ActionDispatch::Request.new(env)
    session.touch_last_accessed!

    if websocket_upgrade?(request)
      hijack_websocket(env, request:, session:, proxied_path:)
    else
      forward_http(request:, session:, proxied_path:)
    end
  end

  private

  # --------------------------------------------------------------------- session

  def resolve_session(token)
    TenantContext.with_system_access do
      PreviewSession.find_accessible_by_token(token)
    end
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => e
    log_error("previews_proxy.session_lookup_failed", token:, error: e.message)
    nil
  end

  # ----------------------------------------------------------------------- http

  def forward_http(request:, session:, proxied_path:)
    upstream_response = Net::HTTP.start(CONNECT_HOST, session.tunnel_port,
      read_timeout: @read_timeout, open_timeout: @open_timeout, use_ssl: false) do |http|
      http.request(build_net_http_request(request:, session:, proxied_path:))
    end
    transform_http_response(session:, upstream_response:)
  end

  def build_net_http_request(request:, session:, proxied_path:)
    request_class = REQUEST_CLASSES[request.request_method]
    raise ArgumentError, "unsupported method #{request.request_method}" unless request_class

    path = build_upstream_path(proxied_path, request.query_string)
    request_class.new(path).then do |net_request|
      upstream_headers = build_upstream_headers(request:, session:)
      upstream_headers.each { |name, value| net_request[name] = value }
      body = read_request_body(request)
      net_request.body = body if body && !body.empty? && net_request.request_body_permitted?
      net_request
    end
  end

  def build_upstream_path(proxied_path, query_string)
    path = proxied_path.to_s
    path = "/" if path.empty?
    query_string.to_s.empty? ? path : "#{path}?#{query_string}"
  end

  def build_upstream_headers(request:, session:)
    headers = collect_request_headers(request.env)
    headers.merge!(
      "host" => "#{CONNECT_HOST}:#{session.tunnel_port}",
      "x-forwarded-host" => original_host(request.env),
      "x-forwarded-port" => client_facing_port(request.env, request.scheme),
      "x-forwarded-proto" => request.scheme
    ).tap do |merged|
      merged["x-forwarded-for"] = compose_forwarded_for(request, merged["x-forwarded-for"])
      merged.delete("content-length")
    end
  end

  def collect_request_headers(env)
    headers = {}
    env.each do |key, value|
      next unless key.start_with?("HTTP_")
      next if key == "HTTP_HOST"

      name = key.sub(/\AHTTP_/, "").tr("_", "-").downcase
      next if HOP_BY_HOP_HEADERS.include?(name)

      headers[name] = value.to_s
    end
    headers["content-type"] = env["CONTENT_TYPE"].to_s if env["CONTENT_TYPE"]
    headers
  end

  def compose_forwarded_for(request, existing)
    client_ip = request.ip.to_s
    return existing.to_s if client_ip.empty?
    return client_ip if existing.to_s.empty?

    "#{existing}, #{client_ip}"
  end

  def read_request_body(request)
    input = request.env["rack.input"]
    return nil unless input

    body = input.read
    input.rewind
    body
  end

  def transform_http_response(session:, upstream_response:)
    headers = transform_response_headers(upstream_response, session:)
    body = upstream_response.body || +""
    headers["content-length"] = body.bytesize.to_s

    [ upstream_response.code.to_i, headers, [ body ] ]
  end

  def transform_response_headers(upstream_response, session:)
    transformed = {}
    content_security_policy_seen = false
    upstream_response.get_fields("set-cookie")&.each do |value|
      append_set_cookie(transformed, rewrite_set_cookie(value, session:))
    end

    upstream_response.each_header do |name, value|
      case name.downcase
      when "x-frame-options"
        next # stripped to allow iframe embedding
      when "content-security-policy"
        content_security_policy_seen = true
        rewritten = rewrite_content_security_policy(value)
        transformed["content-security-policy"] = rewritten if rewritten
      when "location"
        transformed["location"] = rewrite_location(value, session:)
      when "set-cookie"
        next
      when *HOP_BY_HOP_HEADERS, "content-length"
        next
      else
        transformed[name.downcase] = value
      end
    end
    # Guarantee iframe embedding even when the upstream omits a CSP entirely.
    unless content_security_policy_seen
      transformed["content-security-policy"] = "frame-ancestors 'self'"
    end
    transformed
  end

  def rewrite_content_security_policy(value)
    directives = value.split(/\s*;\s*/).reject(&:empty?)
    filtered = directives.reject { |directive| directive.split.first&.downcase == "frame-ancestors" }
    # The preview iframe is same-origin with the Rails app, so 'self' permits
    # embedding in the wrapper page without allowing arbitrary third-party sites.
    filtered << "frame-ancestors 'self'"
    filtered.join("; ")
  end

  def rewrite_location(value, session:)
    uri = URI.parse(value.to_s)
    if uri.host.nil?
      path = uri.path.empty? ? "/" : uri.path
      uri.path = "#{session.proxy_prefix}#{dedupe_slash(path)}"
    elsif upstream_origin?(uri)
      uri.scheme = nil
      uri.host = nil
      uri.port = nil
      path = uri.path.empty? ? "/" : uri.path
      uri.path = "#{session.proxy_prefix}#{dedupe_slash(path)}"
    end
    uri.to_s
  rescue URI::InvalidURIError
    value
  end

  # Removes any Domain= attribute so the cookie scopes to the exact proxy
  # origin and rewrites Path= so the browser only sends the cookie back to the
  # current preview prefix instead of the whole Paid app origin.
  def rewrite_set_cookie(value, session:)
    parts = value.to_s.split(/;\s*/)
    cookie = parts.shift.to_s
    path = parts.find { |part| part.match?(/\Apath=/i) }&.split("=", 2)&.last
    attributes = parts.reject { |part| part.match?(/\A(?:domain|path)=/i) }

    [ cookie, "Path=#{rewrite_cookie_path(path, session.proxy_prefix)}", *attributes ].join("; ")
  end

  def append_set_cookie(headers, value)
    if headers["set-cookie"]
      headers["set-cookie"] = "#{headers['set-cookie']}\n#{value}"
    else
      headers["set-cookie"] = value
    end
  end

  # ----------------------------------------------------------------- websocket

  def websocket_upgrade?(request)
    connection = request.get_header("HTTP_CONNECTION").to_s
    upgrade = request.get_header("HTTP_UPGRADE").to_s
    connection.downcase.split(/[,\s]+/).include?("upgrade") && upgrade.downcase == "websocket"
  end

  def hijack_websocket(env, request:, session:, proxied_path:)
    return error_response(status: 502, message: "WebSocket hijack unsupported") unless env["rack.hijack?"]

    env["rack.hijack"].call
    client_io = env["rack.hijack_io"]

    upstream = open_websocket_upstream_socket(session.tunnel_port)
    upstream.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

    raw_request = build_raw_upgrade_request(request:, session:, proxied_path:)
    upstream.write(raw_request)
    upstream.flush

    response_head = read_until_delimiter(upstream, "\r\n\r\n", timeout: @open_timeout)
    client_io.write(response_head)
    client_io.flush

    pipe_bidirectionally(client_io, upstream)

    # Connection is fully hijacked; the written response owns the socket.
    [ -1, {}, [] ]
  rescue StandardError => e
    log_error("previews_proxy.websocket_failed", token: session.token, error: e.message)
    write_socket_error(client_io)
    [ -1, {}, [] ]
  ensure
    upstream&.close unless upstream.nil?
    client_io&.close unless client_io.nil?
  end

  def build_raw_upgrade_request(request:, session:, proxied_path:)
    headers = collect_websocket_request_headers(request.env)
    headers["host"] = "#{CONNECT_HOST}:#{session.tunnel_port}"
    headers["x-forwarded-host"] = original_host(request.env)
    headers["x-forwarded-proto"] = request.scheme
    headers["x-forwarded-port"] = client_facing_port(request.env, request.scheme)
    headers["x-forwarded-for"] = compose_forwarded_for(request, headers["x-forwarded-for"])

    path = build_upstream_path(proxied_path, request.query_string)
    lines = [ "#{request.request_method} #{path} HTTP/1.1" ]
    headers.each { |name, value| lines << "#{capitalize_header(name)}: #{value}" }
    lines.join("\r\n") << "\r\n\r\n"
  end

  def collect_websocket_request_headers(env)
    # For WebSocket upgrades we MUST retain Connection/Upgrade so the upstream
    # completes the handshake, so hop-by-hop headers are forwarded verbatim.
    headers = {}
    env.each do |key, value|
      next unless key.start_with?("HTTP_")
      next if key == "HTTP_HOST"

      name = key.sub(/\AHTTP_/, "").tr("_", "-").downcase
      headers[name] = value.to_s
    end
    headers["content-type"] = env["CONTENT_TYPE"].to_s if env["CONTENT_TYPE"]
    headers
  end

  def open_websocket_upstream_socket(port)
    Timeout.timeout(@open_timeout, Net::OpenTimeout) do
      TCPSocket.new(CONNECT_HOST, port)
    end
  end

  def read_until_delimiter(socket, delimiter, timeout:)
    buffer = +""
    Timeout.timeout(timeout, Net::ReadTimeout) do
      loop do
        chunk = socket.readpartial(BUFFER_SIZE)
        buffer << chunk
        break if buffer.include?(delimiter)
      end
    end
    buffer
  rescue EOFError
    buffer
  end

  def pipe_bidirectionally(client_io, upstream_io)
    completion = Queue.new
    threads = [
      spawn_pipe_thread(client_io, upstream_io, completion),
      spawn_pipe_thread(upstream_io, client_io, completion)
    ]
    # Wait for either direction to close, then close both sockets so the
    # surviving direction's readpartial unblocks, and reap the threads.
    completion.pop
    [ client_io, upstream_io ].each { |io| io.close unless io.closed? }
    threads.each { |thread| thread.join(2) }
  end

  def spawn_pipe_thread(input, output, completion)
    Thread.new do
      Thread.current.abort_on_exception = false
      begin
        loop do
          data = input.readpartial(BUFFER_SIZE)
          output.write(data)
          output.flush
        end
      rescue EOFError, IOError, SystemCallError
        # One side closed normally; signal the bidirectional pipe to wind down.
      ensure
        completion << true
      end
    end
  end

  def write_socket_error(io)
    return unless io && !io.closed?

    body = "Preview websocket upstream unavailable."
    response = "HTTP/1.1 502 Bad Gateway\r\n" \
               "Content-Type: text/plain\r\n" \
               "Content-Length: #{body.bytesize}\r\n" \
               "Connection: close\r\n\r\n#{body}"
    io.write(response)
    io.flush
  rescue IOError, SystemCallError
    # Socket already gone; nothing more to do.
  end

  # -------------------------------------------------------------------- helpers

  def original_host(env)
    forwarded_host(env) || "localhost"
  end

  def client_facing_port(env, scheme)
    env["HTTP_X_FORWARDED_PORT"].presence || port_from_host(forwarded_host(env)) || default_port_for_scheme(scheme)
  end

  def forwarded_host(env)
    env["HTTP_X_FORWARDED_HOST"].to_s.split(/\s*,\s*/).first.presence || env["HTTP_HOST"].presence
  end

  def port_from_host(host)
    return if host.blank?
    return Regexp.last_match(1) if host.match(/\A\[[^\]]+\]:(\d+)\z/)
    return unless host.count(":") == 1

    host[%r{:(\d+)\z}, 1]
  end

  def default_port_for_scheme(scheme)
    scheme == "https" ? "443" : "80"
  end

  def rewrite_cookie_path(path, proxy_prefix)
    return "#{proxy_prefix}/" if path.blank?

    "#{proxy_prefix}#{dedupe_slash(path)}"
  end

  def upstream_origin?(uri)
    uri.host == CONNECT_HOST
  end

  def dedupe_slash(path)
    return path if path.empty?

    path.start_with?("/") ? path : "/#{path}"
  end

  def capitalize_header(name)
    name.split("-").map(&:capitalize).join("-")
  end

  def not_found
    body = "Not Found"
    [ 404, { "content-type" => "text/plain; charset=utf-8", "content-length" => body.bytesize.to_s }, [ body ] ]
  end

  def error_response(status: 502, message: "Preview upstream unavailable")
    [ status, { "content-type" => "text/plain; charset=utf-8", "content-length" => message.bytesize.to_s }, [ message ] ]
  end

  def log_error(message, **payload)
    Rails.logger.error(payload.merge(message: message, component: "preview_proxy"))
  end
end
