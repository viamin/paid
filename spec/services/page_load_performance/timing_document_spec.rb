# frozen_string_literal: true

require "rails_helper"

RSpec.describe PageLoadPerformance::TimingDocument do
  def route(overrides = {})
    {
      "path" => "/dashboard",
      "http_status" => 200,
      "samples" => 3,
      "metrics" => {
        "load_ms" => { "median" => 810, "min" => 780, "max" => 903, "values" => [ 780, 810, 903 ] }
      }
    }.merge(overrides)
  end

  def parse(routes, **opts)
    described_class.parse({ "routes" => routes }, **opts)
  end

  # @spec PAGE-LOAD-MEASURE-013
  it "keeps a well-formed document intact" do
    document = parse({ "dashboard" => route })

    expect(document["routes"]["dashboard"]["metrics"]["load_ms"]["median"]).to eq(810)
    expect(document["routes"]["dashboard"]["http_status"]).to eq(200)
  end

  # @spec PAGE-LOAD-MEASURE-013
  it "drops routes past the route cap" do
    routes = 40.times.index_with { route }.transform_keys { |i| "route-#{i}" }

    document = parse(routes, max_routes: 5)

    expect(document["routes"].size).to eq(5)
  end

  # @spec PAGE-LOAD-MEASURE-013
  it "truncates route names and paths to their stored width" do
    document = parse({ "r" * 500 => route("path" => "/#{"p" * 4000}") })

    name = document["routes"].keys.sole
    expect(name.length).to eq(PageLoadPerformance::TimingDocument::MAX_ROUTE_NAME)
    expect(document["routes"][name]["path"].length).to eq(PageLoadPerformance::TimingDocument::MAX_ROUTE_PATH)
  end

  # @spec PAGE-LOAD-MEASURE-013
  it "discards non-positive and out-of-range metric values" do
    document = parse({ "dashboard" => route("metrics" => {
      "load_ms" => { "median" => 0, "values" => [ 0 ] },
      "lcp_ms" => { "median" => 900_000_000, "values" => [ 900_000_000 ] },
      "ttfb_ms" => { "median" => -5, "values" => [ -5 ] },
      "fcp_ms" => { "median" => "not a number", "values" => [ "not a number" ] },
      "dcl_ms" => { "median" => 420, "values" => [ 420 ] }
    }) })

    expect(document["routes"]["dashboard"]["metrics"].keys).to eq([ "dcl_ms" ])
  end

  # @spec PAGE-LOAD-MEASURE-013
  it "caps retained sample values at the number of samples requested" do
    values = Array.new(5_000) { 800 }
    document = parse({ "dashboard" => route("metrics" => {
      "load_ms" => { "median" => 800, "values" => values }
    }) }, max_samples: 3)

    expect(document["routes"]["dashboard"]["metrics"]["load_ms"]["values"].size).to eq(3)
  end

  # @spec PAGE-LOAD-MEASURE-013
  it "coerces an implausible HTTP status to nil" do
    document = parse({ "dashboard" => route("http_status" => "; DROP TABLE") })

    expect(document["routes"]["dashboard"]["http_status"]).to be_nil
  end

  # @spec PAGE-LOAD-MEASURE-013
  it "returns nil for a document that is not a routes mapping" do
    expect(described_class.parse([ "nope" ])).to be_nil
    expect(described_class.parse({ "routes" => "nope" })).to be_nil
  end

  # @spec PAGE-LOAD-MEASURE-013
  it "drops a route whose metrics are all rejected" do
    document = parse({ "dashboard" => route("metrics" => { "load_ms" => { "median" => 0 } }) })

    expect(document["routes"]).to be_empty
  end
end
