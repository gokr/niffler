/* niffler website — minimal interactivity */

(function () {
  "use strict";

  var el = document.querySelector(".typed");
  if (!el) return;

  // The typed command is localized (i18n.js exposes the active catalog);
  // the fallback is the English text baked into the HTML data attribute.
  var fallback = "niffler — waiting for input…";
  var i = 0;
  function cmd() {
    if (el.dataset.i18n && window.NIFFLER_I18N) {
      return window.NIFFLER_I18N.text(el.dataset.i18n, fallback);
    }
    return fallback;
  }
  function type() {
    // Re-resolve each cycle so a mid-session locale switch takes effect.
    var text = cmd();
    if (i <= text.length) {
      el.textContent = text.slice(0, i++);
      setTimeout(type, 45);
    } else {
      setTimeout(function () {
        el.textContent = "";
        i = 0;
        type();
      }, 4200);
    }
  }
  type();

  var revealEls = document.querySelectorAll(".card, .step, .arch, .table-wrap, .term, .wire, .status, .qs");
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.style.opacity = "1";
          entry.target.style.transform = "none";
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.08 });
    revealEls.forEach(function (el) {
      el.style.opacity = "0";
      el.style.transform = "translateY(8px)";
      el.style.transition = "opacity 0.5s ease, transform 0.5s ease";
      io.observe(el);
    });
  }
})();
