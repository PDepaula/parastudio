"use strict";
// The docs site's three small behaviours: the look switch, the menu drawer on a phone, and search
// over search-index.js (built with the site; nothing is fetched from anywhere).
(function () {
  const $ = (id) => document.getElementById(id);
  const root = document.documentElement;

  // --- the look: follow the computer, light, dark --------------------------------------------
  const themeKey = "parastudio-docs-theme";
  const themeNames = { "": "follow the computer", light: "light", dark: "dark" };
  const nextTheme = { "": "light", light: "dark", dark: "" };
  const themeBtn = $("theme-btn");
  function showTheme() {
    const cur = root.dataset.theme || "";
    themeBtn.setAttribute("aria-label", "Look: " + themeNames[cur] + ". Switch to " + themeNames[nextTheme[cur]]);
    themeBtn.title = themeBtn.getAttribute("aria-label");
  }
  themeBtn.addEventListener("click", () => {
    const next = nextTheme[root.dataset.theme || ""];
    if (next) root.dataset.theme = next; else delete root.dataset.theme;
    try { if (next) localStorage.setItem(themeKey, next); else localStorage.removeItem(themeKey); } catch (e) { /* storage off: lasts until reload */ }
    showTheme();
  });
  showTheme();

  // --- the menu drawer (narrow windows) -------------------------------------------------------
  const menuBtn = $("menu-btn"), side = $("side"), scrim = $("scrim");
  function drawer(open) {
    document.body.classList.toggle("drawer-open", open);
    menuBtn.setAttribute("aria-expanded", String(open));
    scrim.hidden = !open;
    // While the menu is open, Tab stays in it: the rest of the page is inert.
    for (const el of document.querySelectorAll(".top, main, .toc")) el.inert = open;
    if (open) (side.querySelector('[aria-current="page"]') || side.querySelector("a")).focus();
    else menuBtn.focus();
  }
  menuBtn.addEventListener("click", () => drawer(true));
  $("side-close").addEventListener("click", () => drawer(false));
  scrim.addEventListener("click", () => drawer(false));
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && document.body.classList.contains("drawer-open")) drawer(false);
  });

  // --- search -------------------------------------------------------------------------------------
  const q = $("q"), box = $("q-box"), list = $("q-list"), status = $("q-status");
  const rows = (window.PARA_SEARCH || []).map((r) => ({ ...r, P: r.p.toLowerCase(), H: r.h.toLowerCase(), T: r.t.toLowerCase() }));
  let hits = [], active = -1;

  function esc(s) { return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]); }
  function mark(text, terms) {
    let out = esc(text);
    for (const t of terms) if (t) out = out.replace(new RegExp("(" + t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ")", "gi"), "<mark>$1</mark>");
    return out;
  }
  function snippet(r, terms) {
    const i = r.T.indexOf(terms[0]);
    if (i < 0) return r.t.slice(0, 120);
    const start = Math.max(0, i - 40);
    return (start ? "…" : "") + r.t.slice(start, start + 140);
  }
  function search(query) {
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    if (!terms.length) return [];
    const scored = [];
    for (const r of rows) {
      let score = 0, all = true;
      for (const t of terms) {
        const inH = r.H.includes(t), inP = r.P.includes(t), inT = r.T.includes(t);
        if (!inH && !inP && !inT) { all = false; break; }
        score += (inH ? 10 : 0) + (inP ? 4 : 0) + (inT ? 1 : 0);
      }
      if (all) scored.push([score, r]);
    }
    scored.sort((a, b) => b[0] - a[0]);
    return scored.slice(0, 12).map((s) => s[1]);
  }
  function setActive(i) {
    active = i;
    [...list.children].forEach((li, n) => li.setAttribute("aria-selected", String(n === i)));
    if (i >= 0 && list.children[i]) {
      q.setAttribute("aria-activedescendant", list.children[i].id);
      list.children[i].scrollIntoView({ block: "nearest" });
    } else q.removeAttribute("aria-activedescendant");
  }
  function close() { box.hidden = true; q.setAttribute("aria-expanded", "false"); setActive(-1); }
  function render() {
    const query = q.value.trim();
    if (!query) { close(); return; }
    hits = search(query);
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    list.innerHTML = hits.map((r, i) =>
      '<li role="option" id="q-opt-' + i + '" aria-selected="false"><a href="' + esc(r.u) + '" tabindex="-1"><b>' + mark(r.h, terms) +
      "</b><small>" + esc(r.p) + " · " + mark(snippet(r, terms), terms) + "</small></a></li>").join("");
    status.textContent = hits.length ? hits.length + " results" : "No results";
    if (!hits.length) list.innerHTML = '<li class="none" role="option" aria-disabled="true" id="q-none">Nothing found. Try another word.</li>';
    box.hidden = false;
    q.setAttribute("aria-expanded", "true");
    setActive(-1);
  }
  q.addEventListener("input", render);
  q.addEventListener("focus", () => { if (q.value.trim()) render(); });
  q.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" && hits.length) { e.preventDefault(); setActive((active + 1) % hits.length); }
    else if (e.key === "ArrowUp" && hits.length) { e.preventDefault(); setActive(active <= 0 ? hits.length - 1 : active - 1); }
    else if (e.key === "Enter") {
      const pick = hits[active >= 0 ? active : 0];
      if (pick) { e.preventDefault(); location.href = pick.u; close(); }
    } else if (e.key === "Escape") { if (!box.hidden) { e.preventDefault(); close(); } else q.value = ""; }
  });
  list.addEventListener("mousedown", (e) => e.preventDefault()); // keep focus in the box while clicking a result
  list.addEventListener("click", (e) => { if (e.target.closest("a")) close(); });
  q.addEventListener("blur", () => setTimeout(close, 0));
  document.addEventListener("keydown", (e) => {
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName) || document.activeElement.isContentEditable;
    if (e.key === "/" && !typing && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); q.focus(); q.select(); }
  });
})();
