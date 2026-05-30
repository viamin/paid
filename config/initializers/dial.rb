# frozen_string_literal: true

return unless defined?(Dial)

Dial.configure do |config|
  # Opt-in profiling. Dial's middleware appends a panel of HTML/CSS/JS to every
  # response with Accept: text/html, which mangles Turbo Frame and Stimulus
  # `innerHTML = await response.text()` flows (e.g. the chat popup, dashboard
  # widget partials). Setting enabled=false routes profiling exclusively through
  # `?profile=1`, so partial XHRs stay clean unless you explicitly target them.
  config.enabled = false
  config.force_param = "profile"
end
