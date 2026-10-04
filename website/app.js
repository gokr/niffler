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
