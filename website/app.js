// Copy buttons: copy the referenced <code>/<pre> text, flash feedback.
document.querySelectorAll("[data-copy-target]").forEach((btn) => {
  btn.addEventListener("click", async () => {
    const target = document.getElementById(btn.dataset.copyTarget);
    if (!target) return;
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      btn.textContent = "copied";
    } catch {
      btn.textContent = "select + copy";
    }
    window.setTimeout(() => { btn.textContent = "copy"; }, 1600);
  });
});

// Wide tables and the application diagram overflow only inside their frame.
// Let a keyboard user inspect them without forcing the whole page sideways.
document.querySelectorAll("[data-i18n-scroll]").forEach((scroller) => {
  const scrollHorizontally = (event) => {
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    let delta = 0;
    if (event.key === "ArrowRight") delta = 80;
    else if (event.key === "ArrowLeft") delta = -80;
    else if (event.key === "Home") delta = -scroller.scrollWidth;
    else if (event.key === "End") delta = scroller.scrollWidth;
    else return;
    event.preventDefault();
    scroller.scrollBy({ left: delta, behavior: "smooth" });
  };
  scroller.addEventListener("keydown", scrollHorizontally);
});
