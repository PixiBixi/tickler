// Theme toggle, copy buttons, click-to-load video, scroll reveals, offscreen pause and the screenshot lightbox.
const root = document.documentElement;
root.classList.remove("no-js");

const setTheme = (theme: string) => {
  root.dataset.theme = theme;
  try {
    localStorage.setItem("tickler-theme", theme);
  } catch {}
};
document.querySelectorAll<HTMLButtonElement>("[data-theme-toggle]").forEach((b) =>
  b.addEventListener("click", () => setTheme(root.dataset.theme === "dark" ? "light" : "dark")),
);

document.querySelectorAll<HTMLButtonElement>("[data-copy]").forEach((btn) => {
  btn.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(btn.dataset.copy ?? "");
      const label = btn.textContent;
      btn.textContent = btn.dataset.copied ?? label;
      setTimeout(() => (btn.textContent = label), 1400);
    } catch {}
  });
});

// The demo mp4 is only fetched on click; until then the poster stands in.
document.querySelectorAll<HTMLElement>("[data-video]").forEach((wrap) => {
  wrap.querySelector("button")?.addEventListener(
    "click",
    () => {
      const v = document.createElement("video");
      v.src = wrap.dataset.video ?? "";
      v.controls = true;
      v.autoplay = true;
      v.playsInline = true;
      v.setAttribute("aria-label", wrap.dataset.label ?? "");
      wrap.replaceChildren(v);
    },
    { once: true },
  );
});

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const reveals = document.querySelectorAll(".reveal");
if (reduce || !("IntersectionObserver" in window)) {
  reveals.forEach((el) => el.classList.add("in"));
} else {
  const io = new IntersectionObserver(
    (entries) =>
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      }),
    { rootMargin: "0px 0px -10% 0px" },
  );
  reveals.forEach((el) => io.observe(el));
}

// The looping hero scene pauses offscreen and in hidden tabs.
const loops = document.querySelectorAll("[data-loop]");
const vis = new IntersectionObserver((entries) =>
  entries.forEach((e) => e.target.classList.toggle("paused", !e.isIntersecting)),
);
loops.forEach((el) => vis.observe(el));
document.addEventListener("visibilitychange", () =>
  loops.forEach((el) => el.classList.toggle("paused", document.hidden)),
);

const dialog = document.querySelector<HTMLDialogElement>("dialog.lightbox");
const big = dialog?.querySelector("img");
if (dialog && big) {
  dialog.querySelector(".close")?.addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog) dialog.close();
  });
  document.querySelectorAll<HTMLButtonElement>("[data-zoom]").forEach((z) =>
    z.addEventListener("click", () => {
      big.src = z.dataset.zoom ?? "";
      big.alt = z.querySelector("img")?.alt ?? "";
      dialog.showModal();
    }),
  );
}
