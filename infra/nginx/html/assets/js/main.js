(function () {
  "use strict";

  var root = document.documentElement;
  var KEY = "homelab-theme";

  function applyTheme(theme) {
    root.setAttribute("data-theme", theme);
  }

  var stored = null;
  try {
    stored = localStorage.getItem(KEY);
  } catch (e) {
    /* storage unavailable; ignore */
  }

  if (stored === "light" || stored === "dark") {
    applyTheme(stored);
  } else if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) {
    applyTheme("dark");
  }

  var toggle = document.getElementById("theme-toggle");
  if (toggle) {
    toggle.addEventListener("click", function () {
      var next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
      applyTheme(next);
      try {
        localStorage.setItem(KEY, next);
      } catch (e) {
        /* ignore */
      }
    });
  }

  var year = document.getElementById("year");
  if (year) {
    year.textContent = String(new Date().getFullYear());
  }
})();
