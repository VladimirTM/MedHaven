// PolyGraph · pagina familiei (E2). Ascultă GET /acasa/events (Server-Sent Events); la „changed” își cere din nou
// propria adresă și înlocuiește conținutul din <main>, ca o bifă din aplicație să apară aici fără refresh.
// Dacă EventSource pică, aceeași reîmprospătare rulează la 5 s. Formularele merg și fără JS (Post/Redirect/Get).
(function () {
  "use strict";

  var main = document.querySelector("main[data-family-live]");
  if (!main || !window.fetch || !window.DOMParser) return;

  var POLL_MS = 5000;
  var source = null;
  var pollTimer = null;
  var running = false;
  var again = false;

  function stale(show) {
    var band = main.querySelector("[data-family-stale]");
    if (band) band.hidden = !show;
  }

  function openDetails() {
    // ce a deschis omul rămâne deschis după înlocuire
    return Array.prototype.map.call(main.querySelectorAll("details[open]"), function (d) {
      var owner = d.closest("[id]");
      return (owner ? owner.id : "") + "|" + (d.className || "");
    });
  }

  function restoreDetails(keys) {
    Array.prototype.forEach.call(main.querySelectorAll("details"), function (d) {
      var owner = d.closest("[id]");
      if (keys.indexOf((owner ? owner.id : "") + "|" + (d.className || "")) !== -1) d.open = true;
    });
  }

  function refresh() {
    if (running) { again = true; return; }
    if (main.querySelector("dialog[open]")) { again = false; return; }
    if (document.activeElement && main.contains(document.activeElement) && document.activeElement.matches("input")) {
      return; // nu înlocuim un formular în care omul scrie (Orele zilei)
    }
    running = true;
    fetch(window.location.pathname + window.location.search, { credentials: "same-origin", cache: "no-store", headers: { Accept: "text/html" } })
      .then(function (response) {
        if (!response.ok) throw new Error("server");
        return response.text();
      })
      .then(function (html) {
        var doc = new DOMParser().parseFromString(html, "text/html");
        var fresh = doc.querySelector("main[data-family-live]");
        if (!fresh) throw new Error("page");
        var keys = openDetails();
        var y = window.scrollY;
        main.innerHTML = fresh.innerHTML;
        restoreDetails(keys);
        window.scrollTo(0, y);
        stale(false);
      })
      .catch(function () { stale(true); })
      .then(function () {
        running = false;
        if (again) { again = false; refresh(); }
      });
  }

  function poll() {
    if (pollTimer) return;
    pollTimer = setInterval(refresh, POLL_MS);
  }

  function listen() {
    if (!window.EventSource) { poll(); return; }
    source = new EventSource(main.getAttribute("data-family-live"));
    source.addEventListener("changed", refresh);
    source.onopen = function () {
      if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    };
    source.onerror = function () {
      // EventSource se reconectează singur; între timp, reîmprospătarea la 5 s
      if (source.readyState === EventSource.CLOSED) { source = null; setTimeout(listen, POLL_MS); }
      poll();
    };
  }

  main.addEventListener("click", function (event) {
    if (event.target.closest("[data-family-retry]")) refresh();
    // E3: compartimentul cutiuței se deschide într-un <dialog> nativ (Escape și butonul ✕ îl închid)
    var opener = event.target.closest("[data-dialog]");
    if (opener) {
      var dialog = document.getElementById(opener.getAttribute("data-dialog"));
      if (dialog && dialog.showModal) dialog.showModal();
    }
  });

  // feedback instant + guard: un buton apăsat nu mai trimite a doua oară
  main.addEventListener("submit", function (event) {
    var button = event.target.querySelector("button[type=submit]");
    if (!button) return;
    if (button.disabled) { event.preventDefault(); return; }
    setTimeout(function () { button.disabled = true; }, 0);
  });

  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible") refresh();
  });

  listen();
})();
