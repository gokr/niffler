/* niffler website — minimal interactivity */

(function () {
  "use strict";

  // Typing demo (index only — pages without .typed skip this)
  var el = document.querySelector(".typed");
  if (el) {
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
  }

  var revealEls = document.querySelectorAll(".card, .step, .arch, .table-wrap, .term, .wire, .status, .qs, .shot");
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

/* ── screenshot lightbox ─────────────────────────────────────────────────
   Links carrying data-lightbox open the target image in an overlay
   (click anywhere, the × button or Esc closes). Without JavaScript the
   anchor keeps its target="_blank" behavior — full image in a new tab. */
(function () {
  var open = false;

  function close(box) {
    if (!open) return;
    open = false;
    box.classList.add("closing");
    setTimeout(function () {
      box.remove();
    }, 150);
    document.removeEventListener("keydown", onKey);
  }

  var current = null;
  function onKey(e) {
    if (e.key === "Escape" && current) close(current);
  }

  document.addEventListener("click", function (e) {
    var link = e.target.closest("a[data-lightbox]");
    if (!link) return;
    e.preventDefault();
    var img = link.querySelector("img");
    var src = link.getAttribute("href");
    var alt = img ? img.alt : link.getAttribute("data-lightbox");

    var box = document.createElement("div");
    box.className = "lightbox";
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-modal", "true");
    box.setAttribute("aria-label", alt);

    var figure = document.createElement("figure");
    figure.style.margin = "0";
    var big = new Image();
    big.src = src;
    big.alt = alt;
    figure.appendChild(big);

    var cap = document.createElement("figcaption");
    cap.textContent = link.getAttribute("data-lightbox") || alt;
    figure.appendChild(cap);
    box.appendChild(figure);

    var x = document.createElement("button");
    x.className = "lightbox-close";
    x.setAttribute("aria-label", "Close");
    x.textContent = "×";
    box.appendChild(x);

    // Click anywhere in the overlay closes; clicking the image itself
    // stays put so accidental drags don't dismiss it.
    box.addEventListener("click", function (ev) {
      if (ev.target === box || ev.target === x || ev.target === cap) close(box);
    });

    document.body.appendChild(box);
    current = box;
    open = true;
    document.addEventListener("keydown", onKey);
    x.focus();
  });
})();
