# frozen_string_literal: true

require "open3"
require "rails_helper"

class ChartkickControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    function installChartkickStub() {
      const createdCharts = [];

      class StubChart {
        constructor(elementId, data, options) {
          this.elementId = elementId;
          this.data = data;
          this.options = options;
          this.destroyed = false;
          createdCharts.push(this);
          global.__chartkickStub.charts[elementId] = this;
        }

        destroy() {
          this.destroyed = true;
        }
      }

      global.__chartkickStub = {
        charts: {},
        LineChart: StubChart
      };

      return createdCharts;
    }

    const createdCharts = installChartkickStub();
    const source = fs.readFileSync("app/javascript/controllers/chartkick_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace('import Chartkick from "chartkick"', "const Chartkick = global.__chartkickStub;")
      .replace("export default class extends Controller {", "return class ChartkickController extends Controller {");

    const ChartkickController = new Function(transformed)();

    function run() {
      const listeners = {};
      const staleChart = {
        destroyed: false,
        destroy() {
          this.destroyed = true;
        }
      };

      global.window = {
        addEventListener(name, callback) {
          listeners[name] = callback;
        },
        removeEventListener(name, callback) {
          if (listeners[name] === callback) delete listeners[name];
        },
        getComputedStyle() {
          return {
            getPropertyValue(name) {
              return {
                "--dashboard-chart-success": "#4ade80",
                "--dashboard-chart-annotation-border": "rgb(251 191 36 / 0.45)"
              }[name] || "";
            }
          };
        }
      };

      global.document = {
        documentElement: {}
      };

      global.__chartkickStub.charts["chart-1"] = staleChart;

      const controller = Object.create(ChartkickController.prototype);
      controller.element = { id: "chart-1" };
      controller.typeValue = "LineChart";
      controller.dataValue = JSON.stringify({ "2026-07-15": 4 });
      controller.optionsValue = JSON.stringify({
        xtitle: "Day",
        colors: ["var(--dashboard-chart-success)"],
        library: {
          plugins: {
            annotation: {
              annotations: {
                x: {
                  borderColor: "var(--dashboard-chart-annotation-border)"
                }
              }
            }
          }
        }
      });

      controller.initialize();
      controller.connect();

      if (!staleChart.destroyed) {
        throw new Error("Expected connect() to destroy any stale chart instance for the same element id");
      }

      if (createdCharts.length !== 1) {
        throw new Error(`Expected connect() to create one Chartkick chart, saw ${createdCharts.length}`);
      }

      const chart = createdCharts[0];
      if (chart.elementId !== "chart-1") {
        throw new Error(`Expected chart to target chart-1, saw ${chart.elementId}`);
      }

      if (chart.options.xtitle !== "Day") {
        throw new Error(`Expected parsed chart options to include xtitle, saw ${JSON.stringify(chart.options)}`);
      }

      if (chart.options.colors[0] !== "#4ade80") {
        throw new Error(`Expected theme token colors to resolve before Chartkick render, saw ${JSON.stringify(chart.options.colors)}`);
      }

      if (chart.options.library.plugins.annotation.annotations.x.borderColor !== "rgb(251 191 36 / 0.45)") {
        throw new Error(`Expected nested theme token to resolve, saw ${chart.options.library.plugins.annotation.annotations.x.borderColor}`);
      }

      listeners["theme:changed"]?.();

      if (createdCharts.length !== 2) {
        throw new Error(`Expected theme change to re-render the chart, saw ${createdCharts.length} charts`);
      }

      controller.disconnect();

      if (!chart.destroyed) {
        throw new Error("Expected disconnect() to destroy the Chartkick instance");
      }

      if (global.__chartkickStub.charts["chart-1"]) {
        throw new Error("Expected disconnect() to remove the Chartkick registry entry");
      }
    }

    try {
      run();
    } catch (error) {
      console.error(error);
      process.exit(1);
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ChartkickControllerNodeHarness, :no_db do
  it "creates and tears down Chartkick charts around Stimulus lifecycle events" do
    stdout, stderr, status = described_class.run

    expect(status.success?).to be(true), <<~MESSAGE
      Node regression harness failed.
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
  end
end
