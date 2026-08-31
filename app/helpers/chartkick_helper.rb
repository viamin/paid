# frozen_string_literal: true

# Overrides Chartkick::Helper#chartkick_chart — the single entry point behind
# the gem's line_chart/column_chart/area_chart helpers — so every chart in the
# app renders through the CSP-safe path described in
# docs/intent/dashboard-chart-accessibility/ and RUNNERS-INDEX-008.
#
# The app enforces `script_src :self` with nonce-only script-src directives
# (config/initializers/content_security_policy.rb), and these charts render
# inside turbo frames fetched by separate requests whose nonces never match
# the host page's policy, so Chartkick's stock inline <script> output is
# blocked and the "Loading..." placeholder never resolves (issues #3458,
# #3622). Instead we emit the chart definition as data attributes on an
# aria-hidden placeholder div that the chartkick Stimulus controller
# (app/javascript/controllers/chartkick_controller.js) instantiates
# client-side, plus an adjacent sr-only <table> exposing the same series data
# to assistive tech.
module ChartkickHelper
  # @spec DASHBOARD-CHART-A11Y-001
  def chartkick_chart(chart_type, data_source, **options)
    @chartkick_chart_id ||= 0

    element_id = options.delete(:id) || "chart-#{@chartkick_chart_id += 1}"
    height, width = chartkick_dimensions(options)
    loading = options.delete(:loading) || "Loading..."
    caption = options.delete(:caption)
    custom_html = options.delete(:html)
    chart_options = options.except(:nonce, :defer, :content_for)
    chart_data = data_source.respond_to?(:chart_json) ? data_source.chart_json : data_source.to_json

    chart_div = if custom_html.present?
      chartkick_custom_placeholder(custom_html, element_id, height, width, loading)
    else
      chartkick_default_placeholder(chart_type, chart_data, chart_options, element_id, height, width, loading)
    end

    safe_join([ chart_div, chartkick_data_table(data_source, caption) ])
  end

  def chartkick_default_placeholder(chart_type, chart_data, chart_options, element_id, height, width, loading)
    tag.div(
      loading,
      id: element_id,
      aria: { hidden: "true" },
      style: "height: #{ERB::Util.html_escape(height)}; width: #{ERB::Util.html_escape(width)}; " \
        "text-align: center; color: #999; line-height: #{ERB::Util.html_escape(height)}; " \
        "font-size: 14px; font-family: 'Lucida Grande', 'Lucida Sans Unicode', Verdana, Arial, Helvetica, sans-serif;",
      data: {
        controller: "chartkick",
        chartkick_type_value: chart_type,
        chartkick_data_value: chart_data,
        chartkick_options_value: chart_options.to_json
      }
    )
  end

  # Preserves the upstream Chartkick::Helper#chartkick_chart `html:` override
  # path (placeholder markup as a %{id}/%{height}/%{width}/%{loading} format
  # string) instead of always emitting the Stimulus-wired placeholder div. A
  # caller that opts into this escape hatch owns the resulting markup,
  # including any data attributes the chartkick controller needs to wire up.
  def chartkick_custom_placeholder(html_template, element_id, height, width, loading)
    html_vars = {
      id: ERB::Util.html_escape(element_id),
      height: ERB::Util.html_escape(height),
      width: ERB::Util.html_escape(width),
      loading: ERB::Util.html_escape(loading)
    }

    (html_template % html_vars).html_safe
  end

  # @spec DASHBOARD-CHART-A11Y-001
  # @spec DASHBOARD-CHART-A11Y-004
  def chartkick_data_table(data_source, caption)
    rows = chartkick_table_rows(data_source)
    return "".html_safe if rows.blank?

    column_names = rows.values.flat_map(&:keys).uniq
    tag.table(class: "sr-only") do
      safe_join([
        caption.present? ? tag.caption(caption) : nil,
        chartkick_table_head(column_names),
        chartkick_table_body(rows, column_names)
      ].compact)
    end
  end

  # @spec DASHBOARD-CHART-A11Y-002
  # @spec DASHBOARD-CHART-A11Y-003
  # @spec DASHBOARD-CHART-A11Y-007
  def chartkick_table_rows(data_source)
    case data_source
    when Array
      if data_source.empty? || !data_source.first.is_a?(Hash)
        # Point-array form: [[label, value], ...] — Chartkick's compact
        # single-series encoding, used by the quality-dashboard trend
        # sparkline and the per-run histogram. Render as a single
        # "Value" column so screen-reader users get the same data the
        # chart conveys.
        data_source.each_with_object({}) do |(label, value), rows|
          rows[label] = { "Value" => value }
        end
      else
        data_source.each_with_object({}) do |series, rows|
          series[:data].each { |label, value| (rows[label] ||= {})[series[:name]] = value }
        end
      end
    when Hash
      data_source.transform_values { |value| { "Value" => value } }
    else
      {}
    end
  end

  def chartkick_table_head(column_names)
    header_cells = column_names.map { |name| tag.th(name) }
    tag.thead(tag.tr(safe_join([ tag.th("") ] + header_cells)))
  end

  def chartkick_table_body(rows, column_names)
    tag.tbody(safe_join(rows.map { |label, values| chartkick_table_row(label, values, column_names) }))
  end

  def chartkick_table_row(label, values, column_names)
    cells = column_names.map { |name| tag.td(chartkick_cell_value(values[name])) }
    tag.tr(safe_join([ tag.th(label.to_s, scope: "row") ] + cells))
  end

  # @spec DASHBOARD-CHART-A11Y-005
  def chartkick_cell_value(value)
    return "No data" if value.nil?

    value.is_a?(Numeric) ? number_with_delimiter(value) : value.to_s
  end

  def chartkick_dimensions(options)
    height = (options.delete(:height) || "300px").to_s
    width = (options.delete(:width) || "100%").to_s

    [ height, width ].each do |value|
      raise ArgumentError, "Invalid height or width" unless /\A[a-zA-Z0-9%.]*\z/.match?(value)
    end

    [ height, width ]
  end
end
