// Refreshes the summary bar in place. Nothing else on the page polls, because
// a dashboard that reloads a table an operator is reading is worse than one
// that shows a stale table with a live total.
(function () {
  "use strict";

  var POLL_INTERVAL = 5000;
  var STORAGE_KEY = "solid-objects-live";

  var timer = null;

  function readPath() {
    return document.body.getAttribute("data-stats-path");
  }

  function lookup(payload, path) {
    return path.split(".").reduce(function (value, key) {
      return value == null ? null : value[key];
    }, payload);
  }

  // Must match SolidObjects::Web::Helpers#number and #duration. A polled cell
  // sits beside server-rendered ones, and a value that changes shape the
  // moment polling starts reads as a different measurement.
  //
  // The cell declares which one it is. A duration of exactly zero arrives from
  // JSON as an integer-valued number, so guessing from the value would print
  // "0" where the server printed "0.000 s".
  function format(value, kind) {
    if (typeof value !== "number") return String(value);
    if (kind !== "duration") return value.toLocaleString("en-US");
    if (value < 60) return value.toFixed(3) + " s";

    return Math.floor(value / 60) + " min " + Math.round(value % 60) + " s";
  }

  function apply(payload) {
    var cells = document.querySelectorAll("[data-statistic]");
    Array.prototype.forEach.call(cells, function (cell) {
      var value = lookup(payload, cell.getAttribute("data-statistic"));
      if (value == null) return;

      var text = format(value, cell.getAttribute("data-format"));
      if (cell.textContent !== text) cell.textContent = text;
    });
  }

  function poll() {
    var path = readPath();
    if (!path) return;

    fetch(path, { credentials: "same-origin", headers: { Accept: "application/json" } })
      .then(function (response) {
        return response.ok ? response.json() : null;
      })
      .then(function (payload) {
        if (!payload) return;

        apply(payload);
        // The charts subscribe to this rather than polling on their own, so
        // one request refreshes every number on the page.
        document.dispatchEvent(
          new CustomEvent("solid-objects:statistics", { detail: payload })
        );
      })
      .catch(function () {
        // A failed poll leaves the last rendered totals in place.
      });
  }

  function setLive(button, live) {
    button.setAttribute("aria-pressed", live ? "true" : "false");

    try {
      window.localStorage.setItem(STORAGE_KEY, live ? "on" : "off");
    } catch (error) {
      // Storage is unavailable in private windows; the toggle still works.
    }

    if (timer) {
      window.clearInterval(timer);
      timer = null;
    }

    if (live) {
      poll();
      timer = window.setInterval(poll, POLL_INTERVAL);
    }
  }

  function stored() {
    try {
      return window.localStorage.getItem(STORAGE_KEY) === "on";
    } catch (error) {
      return false;
    }
  }

  function start() {
    var button = document.querySelector("[data-poll-toggle]");
    if (!button) return;

    button.addEventListener("click", function () {
      setLive(button, button.getAttribute("aria-pressed") !== "true");
    });

    if (stored()) setLive(button, true);
  }

  // The tag is deferred, so the document is usually still parsing. A script
  // evaluated after the document finished would never see the event, and
  // waiting for one that already fired leaves the toggle inert.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
