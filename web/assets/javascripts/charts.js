// Draws the dashboard charts. Each canvas carries its own data in a
// data-chart-values attribute, so this file never fetches on load and the page
// needs no script-src exception for an inline block.
//
// Two of the three charts redraw when the Live poller reports new totals. The
// third counts instances per actor type, which /stats does not carry, so it
// stays as the page rendered it.
(function () {
  "use strict";

  // Every status gets its own colour. Related statuses stay in the same
  // family, because a legend with two identical swatches reads as a defect
  // even when the two statuses genuinely mean the same thing.
  var STATUS_COLORS = {
    pending: "#d29922",
    paused: "#e07b39",
    processing: "#4493f8",
    scheduled: "#7c72ff",
    completed: "#3fb950",
    delivered: "#2ea8a0",
    dead: "#f85149"
  };

  var SERIES_COLOR = "#4493f8";
  var charts = {};

  function palette() {
    var styles = window.getComputedStyle(document.body);
    return {
      text: styles.getPropertyValue("--text-muted").trim() || "#626d7a",
      grid: styles.getPropertyValue("--border").trim() || "#dfe3e8"
    };
  }

  function values(canvas) {
    try {
      return JSON.parse(canvas.getAttribute("data-chart-values"));
    } catch (error) {
      return null;
    }
  }

  function baseOptions(colors) {
    return {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 200 },
      plugins: { legend: { display: false } },
      scales: {
        x: { ticks: { color: colors.text }, grid: { color: colors.grid } },
        y: {
          beginAtZero: true,
          ticks: { color: colors.text, precision: 0 },
          grid: { color: colors.grid }
        }
      }
    };
  }

  function barChart(canvas, data, colors, options) {
    var labels = Object.keys(data);
    var settings = baseOptions(colors);
    if (options && options.horizontal) settings.indexAxis = "y";

    return new window.Chart(canvas, {
      type: "bar",
      data: {
        labels: labels,
        datasets: [
          {
            data: labels.map(function (label) {
              return data[label];
            }),
            backgroundColor: SERIES_COLOR,
            borderRadius: 4,
            maxBarThickness: 36
          }
        ]
      },
      options: settings
    });
  }

  // One dataset per status so each row shows only the statuses its subsystem
  // actually has; a subsystem without a status contributes zero to it.
  function stackedChart(canvas, data, colors) {
    var rows = Object.keys(data);
    var statuses = [];
    rows.forEach(function (row) {
      Object.keys(data[row]).forEach(function (status) {
        if (statuses.indexOf(status) === -1) statuses.push(status);
      });
    });

    var settings = baseOptions(colors);
    settings.indexAxis = "y";
    settings.plugins.legend = { display: true, labels: { color: colors.text } };
    settings.scales.x.stacked = true;
    settings.scales.y.stacked = true;

    return new window.Chart(canvas, {
      type: "bar",
      data: {
        labels: rows,
        datasets: statuses.map(function (status) {
          return {
            label: status,
            backgroundColor: STATUS_COLORS[status] || SERIES_COLOR,
            borderRadius: 2,
            data: rows.map(function (row) {
              return data[row][status] || 0;
            })
          };
        })
      },
      options: settings
    });
  }

  function build(canvas) {
    var name = canvas.getAttribute("data-chart");
    var data = values(canvas);
    if (!data) return;

    var colors = palette();
    if (name === "work_by_status") {
      charts[name] = stackedChart(canvas, data, colors);
      return;
    }

    charts[name] = barChart(canvas, data, colors, {
      horizontal: name === "instances_by_type"
    });
  }

  function replace(chart, data) {
    chart.data.datasets.forEach(function (dataset) {
      if (!dataset.label) {
        dataset.data = chart.data.labels.map(function (label) {
          return data[label] || 0;
        });
        return;
      }

      dataset.data = chart.data.labels.map(function (row) {
        return (data[row] || {})[dataset.label] || 0;
      });
    });
    chart.update();
  }

  function refresh(statistics) {
    if (charts.mailbox_depth) {
      replace(charts.mailbox_depth, {
        Ready: statistics.mailbox.ready,
        Due: statistics.mailbox.due,
        Claimed: statistics.mailbox.claimed
      });
    }

    if (charts.work_by_status) {
      replace(charts.work_by_status, {
        Effects: statistics.effects,
        Broadcasts: statistics.broadcasts,
        Reminders: statistics.reminders
      });
    }
  }

  function start() {
    if (!window.Chart) return;

    var canvases = document.querySelectorAll("[data-chart]");
    Array.prototype.forEach.call(canvases, build);

    document.addEventListener("solid-objects:statistics", function (event) {
      try {
        refresh(event.detail);
      } catch (error) {
        // A payload missing a section leaves the drawn chart alone.
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
