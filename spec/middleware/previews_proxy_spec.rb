# frozen_string_literal: true

require "rails_helper"
require "rack/mock"

RSpec.describe PreviewsProxy do
  let(:fallback_app) do
    ->(_env) { [ 200, { "content-type" => "text/plain" }, [ "fallback" ] ] }
  end
  let(:middleware) { described_class.new(fallback_app) }
  let(:mock_request) { Rack::MockRequest.new(middleware) }

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let!(:session) do
    create(:preview_session, project: project, status: "active",
      token: "s3cret-token", expires_at: 30.minutes.from_now)
  end
  let(:port) { session.tunnel_port }

  describe "path routing" do
    it "passes non-preview paths through to the app" do
      response = mock_request.get("/dashboard")

      expect(response.status).to eq(200)
      expect(response.body).to eq("fallback")
    end

    it "passes the exact /previews/:id through to the app (controller route)" do
      response = mock_request.get("/previews/s3cret-token")

      expect(response.body).to eq("fallback")
    end
  end

  describe "token validation" do
    it "returns 404 (not 403) for an unknown token to avoid leaking existence" do
      response = mock_request.get("/previews/no-such-token/issues/42")

      expect(response.status).to eq(404)
    end

    it "returns 404 for an expired session" do
      create(:preview_session, :expired, token: "expired", project: project)

      response = mock_request.get("/previews/expired/issues/42")

      expect(response.status).to eq(404)
    end

    it "returns 404 for a stopped session" do
      create(:preview_session, :stopped, token: "stopped", project: project)

      response = mock_request.get("/previews/stopped/issues/42")

      expect(response.status).to eq(404)
    end

    it "returns 404 for a session without an allocated tunnel port" do
      create(:preview_session, :without_port, status: "active", token: "no-port", project: project)

      response = mock_request.get("/previews/no-port/issues/42")

      expect(response.status).to eq(404)
    end
  end

  describe "HTTP forwarding" do
    before do
      stub_request(:any, %r{\Ahttp://127\.0\.0\.1:#{port}/})
    end

    it "forwards the request to the resolved tunnel port and returns the body" do
      stub_request(:get, "http://127.0.0.1:#{port}/issues/42")
        .to_return(status: 200, body: "<h1>Issue 42</h1>")

      response = mock_request.get("/previews/s3cret-token/issues/42")

      expect(response.status).to eq(200)
      expect(response.body).to eq("<h1>Issue 42</h1>")
    end

    it "preserves the query string when forwarding" do
      stub_request(:get, "http://127.0.0.1:#{port}/search")
        .with(query: { q: "rails" })
        .to_return(status: 200, body: "ok")

      response = mock_request.get("/previews/s3cret-token/search?q=rails")

      expect(response.status).to eq(200)
    end

    it "deletes the X-Frame-Options header" do
      stub_request(:get, "http://127.0.0.1:#{port}/")
        .to_return(status: 200, headers: { "X-Frame-Options" => "DENY" }, body: "ok")

      response = mock_request.get("/previews/s3cret-token/")

      expect(response.headers).not_to have_key("x-frame-options")
      expect(response.headers).not_to have_key("X-Frame-Options")
    end

    it "rewrites Content-Security-Policy frame-ancestors to allow embedding" do
      stub_request(:get, "http://127.0.0.1:#{port}/")
        .to_return(
          status: 200,
          headers: { "Content-Security-Policy" => "frame-ancestors 'self'; default-src 'self'" },
          body: "ok"
        )

      response = mock_request.get("/previews/s3cret-token/")

      csp = response.headers["content-security-policy"]
      expect(csp).to include("frame-ancestors 'self'")
      expect(csp).to include("default-src 'self'")
    end

    it "adds frame-ancestors 'self' when the upstream has no CSP" do
      stub_request(:get, "http://127.0.0.1:#{port}/")
        .to_return(status: 200, body: "ok")

      response = mock_request.get("/previews/s3cret-token/")

      expect(response.headers["content-security-policy"]).to eq("frame-ancestors 'self'")
    end

    it "rewrites a relative Location redirect to stay within the proxy" do
      stub_request(:post, "http://127.0.0.1:#{port}/login")
        .to_return(status: 302, headers: { "Location" => "/dashboard" }, body: "")

      response = mock_request.post("/previews/s3cret-token/login", input: "x=1")

      expect(response.status).to eq(302)
      expect(response.headers["location"]).to eq("/previews/s3cret-token/dashboard")
    end

    it "rewrites an absolute Location pointing at the upstream host" do
      stub_request(:get, "http://127.0.0.1:#{port}/legacy")
        .to_return(status: 301, headers: { "Location" => "http://127.0.0.1:#{port}/new" }, body: "")

      response = mock_request.get("/previews/s3cret-token/legacy")

      expect(response.headers["location"]).to eq("/previews/s3cret-token/new")
    end

    it "rewrites Set-Cookie scoping to the current preview prefix" do
      stub_request(:get, "http://127.0.0.1:#{port}/")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "session=abc; Path=/; Domain=app.internal; HttpOnly" },
          body: "ok"
        )

      response = mock_request.get("/previews/s3cret-token/")

      cookie = response.headers["set-cookie"]
      expect(cookie).to include("session=abc")
      expect(cookie).not_to match(/domain=/i)
      expect(cookie).to include("Path=/previews/s3cret-token/")
      expect(cookie).to include("HttpOnly")
    end

    it "preserves repeated Set-Cookie headers as separate cookies" do
      upstream_response = instance_double(
        Net::HTTPOK,
        body: "ok",
        code: "200"
      )
      allow(upstream_response).to receive(:get_fields).with("set-cookie").and_return([
        "session=abc; Path=/; Domain=app.internal; HttpOnly",
        "csrf=xyz; Path=/; Domain=app.internal; Secure"
      ])
      allow(upstream_response).to receive(:each_header).and_yield("content-type", "text/plain")
      allow(Net::HTTP).to receive(:start).and_return(upstream_response)

      response = mock_request.get("/previews/s3cret-token/")

      cookies = response.headers["set-cookie"].split("\n")
      expect(cookies).to eq([
        "session=abc; Path=/previews/s3cret-token/; HttpOnly",
        "csrf=xyz; Path=/previews/s3cret-token/; Secure"
      ])
    end

    it "keeps non-root cookie paths scoped beneath the preview prefix" do
      stub_request(:get, "http://127.0.0.1:#{port}/")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "session=abc; Path=/admin; Domain=app.internal; HttpOnly" },
          body: "ok"
        )

      response = mock_request.get("/previews/s3cret-token/")

      expect(response.headers["set-cookie"]).to eq("session=abc; Path=/previews/s3cret-token/admin; HttpOnly")
    end

    it "sets X-Forwarded-Host to the proxy origin on the forwarded request" do
      stub_request(:get, "http://127.0.0.1:#{port}/")
        .to_return(status: 200, body: "ok")

      mock_request.get("/previews/s3cret-token/", "HTTP_HOST" => "paid.example")

      expect(WebMock).to have_requested(:get, "http://127.0.0.1:#{port}/")
        .with(headers: { "X-Forwarded-Host" => "paid.example" })
    end

    it "sets X-Forwarded-Port to the client-facing port on the forwarded request" do
      stub_request(:get, "http://127.0.0.1:#{port}/")
        .to_return(status: 200, body: "ok")

      mock_request.get("/previews/s3cret-token/", "HTTP_HOST" => "paid.example:8443")

      expect(WebMock).to have_requested(:get, "http://127.0.0.1:#{port}/")
        .with(headers: { "X-Forwarded-Port" => "8443" })
    end

    it "forwards POST bodies" do
      stub_request(:post, "http://127.0.0.1:#{port}/users")
        .to_return(status: 201, body: "created")

      response = mock_request.post("/previews/s3cret-token/users", input: "name=alice")

      expect(response.status).to eq(201)
      expect(WebMock).to have_requested(:post, "http://127.0.0.1:#{port}/users")
        .with(body: "name=alice")
    end

    it "returns 502 when the upstream is unreachable" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED, "Connection refused")

      response = mock_request.get("/previews/s3cret-token/issues/42")

      expect(response.status).to eq(502)
    end
  end

  describe "WebSocket upgrade", :websocket do
    it "pipes the upgrade handshake and bidirectional frames to the upstream" do
      with_websocket_upstream(port) do |upstream_received|
        client_io, client_mirror = Socket.pair(:UNIX, :STREAM, 0)
        env = websocket_env_for(client_io)

        thread = Thread.new { middleware.call(env) }
        thread.abort_on_exception = false

        # Client reads the 101 Switching Protocols written by the proxy.
        expect(read_until(client_mirror, "\r\n\r\n", timeout: 2)).to include("101")

        # Client sends a frame; upstream echoes it back through the proxy.
        client_mirror.write("ping-from-client")
        expect(read_until(client_mirror, "ping-from-client", timeout: 2)).to include("ping-from-client")

        forwarded = upstream_received.call
        expect(forwarded).to include("Upgrade: websocket")
        expect(forwarded).to include("GET /cable")
        expect(forwarded).to include("X-Forwarded-Port: 80")

        client_mirror.close
        thread.join(2)
      end
    end

    it "returns a 502 over the hijacked socket when the upstream handshake stalls" do
      middleware = described_class.new(fallback_app, open_timeout: 0.01)
      client_io, client_mirror = Socket.pair(:UNIX, :STREAM, 0)
      env = websocket_env_for(client_io)

      allow(TCPSocket).to receive(:new).and_return(stalled_socket)

      thread = Thread.new { middleware.call(env) }
      thread.abort_on_exception = false

      response = read_until(client_mirror, "\r\n\r\n", timeout: 2)

      expect(response).to include("502 Bad Gateway")
      expect(response).to include("Preview websocket upstream unavailable.")

      client_mirror.close
      thread.join(2)
    end
  end

  describe "request path filtering" do
    it "redacts preview tokens from filtered request paths used by request logging" do
      request = ActionDispatch::Request.new(Rack::MockRequest.env_for(
        "/previews/s3cret-token/issues/42?token=query-token&view=full"
      ).merge("action_dispatch.parameter_filter" => Rails.application.config.filter_parameters))

      expect(request.filtered_path).to eq("/previews/[FILTERED]/issues/42?token=[FILTERED]&view=full")
    end

    it "does not redact the iframe wrapper route without a proxied path" do
      request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/previews/123").merge(
        "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters
      ))

      expect(request.filtered_path).to eq("/previews/123")
    end
  end

  def websocket_env_for(client_io)
    env = Rack::MockRequest.env_for("/previews/s3cret-token/cable",
      "HTTP_HOST" => "paid.example",
      "HTTP_CONNECTION" => "Upgrade",
      "HTTP_UPGRADE" => "websocket",
      "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
      "HTTP_SEC_WEBSOCKET_VERSION" => "13")
    env["rack.hijack?"] = true
    env["rack.hijack"] = -> { env["rack.hijack_io"] = client_io }
    env
  end

  # Starts a real TCP server on +port+ that completes a WebSocket handshake
  # (responds 101) and echoes any bytes it receives. Yields an accessor that
  # returns the raw request the proxy forwarded to the upstream.
  def with_websocket_upstream(port)
    server = TCPServer.new("127.0.0.1", port)
    received = +""
    server_thread = Thread.new do
      Thread.current.abort_on_exception = false
      client = server.accept
      received << client.readpartial(4096) until received.include?("\r\n\r\n")
      client.write("HTTP/1.1 101 Switching Protocols\r\n" \
                   "Upgrade: websocket\r\n" \
                   "Connection: Upgrade\r\n" \
                   "Sec-WebSocket-Accept: fixed\r\n\r\n")
      client.flush
      # Echo loop
      loop do
        data = client.readpartial(4096)
        client.write(data)
        client.flush
      rescue EOFError, IOError, SystemCallError
        break
      end
    ensure
      client&.close
    end

    yield -> { received.to_s }
  ensure
    server_thread&.join(2)
    server&.close
  end

  def stalled_socket
    instance_double(TCPSocket,
      setsockopt: true,
      write: true,
      flush: true,
      close: true,
      nil?: false,
      closed?: false).tap do |socket|
      allow(socket).to receive(:readpartial) do
        sleep 0.1
        "HTTP/1.1 101 Switching Protocols\r\n"
      end
    end
  end

  def read_until(io, delimiter, timeout:)
    buffer = +""
    deadline = Time.now + timeout
    loop do
      return buffer if buffer.include?(delimiter)
      raise Timeout::Error if Time.now >= deadline

      if io.wait_readable(0.05)
        begin
          chunk = io.read_nonblock(4096)
          return buffer if chunk.nil? || chunk.empty?

          buffer << chunk
        rescue IO::WaitReadable
          next
        rescue EOFError
          return buffer
        end
      end
    end
  end
end
