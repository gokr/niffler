// Theme handling: a "dark" class on <html> plus a localStorage override
// of the OS default. index.html applies the same logic inline before first
// paint so there is no flash of the wrong theme.

const KEY = "niffler-theme";

type Theme = "light" | "dark";

function storedTheme(): Theme | null {
  const t = localStorage.getItem(KEY);
  return t === "light" || t === "dark" ? t : null;
}

export function applyTheme(t: Theme): void {
  document.documentElement.classList.toggle("dark", t === "dark");
}

export function initTheme(): Theme {
  const t = storedTheme() ?? systemTheme();
  applyTheme(t);
  // Follow the OS until the user picks a side explicitly.
  if (!storedTheme()) {
    window
      .matchMedia("(prefers-color-scheme: dark)")
      .addEventListener("change", (e) => {
        if (!storedTheme()) applyTheme(e.matches ? "dark" : "light");
      });
  }
  return t;
}

export function toggleTheme(): Theme {
  const t: Theme =
    document.documentElement.classList.contains("dark") ? "light" : "dark";
  localStorage.setItem(KEY, t);
  applyTheme(t);
  return t;
}

export function systemTheme(): Theme {
  return window.matchMedia("(prefers-color-scheme: light)").matches
    ? "light"
    : "dark";
}
