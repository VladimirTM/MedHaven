// PolyGraph · portalul se actualizează singur (QA5.1). Pagina ascultă GET /portal/events (Server-Sent Events); la un
// eveniment își cere din nou propria adresă și înlocuiește doar fragmentele [data-live-part] care s-au schimbat.
// Dacă EventSource pică, aceeași reîmprospătare rulează la 5 s.
(function () {
  "use strict";

  var main = document.querySelector("main[data-live]");
  if (!main || !window.fetch || !window.DOMParser) return;

  var POLL_MS = 5000;
  var COALESCE_MS = 250;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  var stale = main.querySelector("[data-live-stale]");
  var source = null;
  var pollTimer = null;
  var queued = null;
  var running = false;
  var again = false;
  var KEYED = /^(alert|med|stat|patient)-/;

  // ---------------------------------------------------------------- reîmprospătarea

  function schedule(delay) {
    if (queued) return;
    queued = setTimeout(function () { queued = null; refresh(); }, delay === undefined ? COALESCE_MS : delay);
  }

  function refresh() {
    if (running) { again = true; return; }
    running = true;
    fetch(window.location.pathname + window.location.search, {
      credentials: "same-origin",
      headers: { Accept: "text/html" },
      cache: "no-store",
    })
      .then(function (response) {
        if (!response.ok) throw new Error("server");
        return response.text();
      })
      .then(function (html) {
        var doc = new DOMParser().parseFromString(html, "text/html");
        // sesiunea a expirat sau pacientul nu mai e în listă: pagina întreagă spune de ce
        if (doc.body.className !== document.body.className || !doc.querySelector("main[data-live]")) {
          window.location.reload();
          return;
        }
        var deferred = apply(doc);
        setStale(false);
        if (deferred) schedule(POLL_MS);
      })
      .catch(function () { setStale(true); })
      .then(function () {
        running = false;
        if (again) { again = false; schedule(); }
      });
  }

  function setStale(on) {
    if (stale) stale.hidden = !on;
  }

  // ce a început medicul să facă într-un fragment (o notă scrisă, „Schimbă”, o decizie pe drum) nu se pierde:
  // fragmentul rămâne cum e și se reîncearcă mai târziu
  function busy(part) {
    if (part.querySelector(".review-form[data-busy]")) return true;
    if (part.querySelector(".alert.is-reviewed .review-form:not([hidden])")) return true;
    var inputs = part.querySelectorAll("input, textarea");
    for (var i = 0; i < inputs.length; i++) {
      if (inputs[i].value !== inputs[i].defaultValue) return true;
    }
    var active = document.activeElement;
    return !!(active && part.contains(active) && /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName));
  }

  function apply(doc) {
    var deferred = false;
    var changed = [];
    main.querySelectorAll("[data-live-part]").forEach(function (part) {
      var next = doc.getElementById(part.id);
      if (!next || next.innerHTML === part.innerHTML) return;
      if (busy(part)) { deferred = true; return; }
      changed.push([part, next]);
    });
    if (changed.length) swap(changed);
    updateGraph(doc);
    return deferred;
  }

  // ---------------------------------------------------------------- înlocuirea, fără flash

  function keyed(root) {
    var out = {};
    root.querySelectorAll("[id]").forEach(function (el) {
      if (KEYED.test(el.id)) out[el.id] = el;
    });
    return out;
  }

  function anchorOf(el, root) {
    var holder = el.closest("[id]");
    return holder && root.contains(holder) ? holder.id : root.id;
  }

  function swap(pairs) {
    var before = {};
    var html = {};
    var openDetails = [];
    var focus = null;
    var active = document.activeElement;

    pairs.forEach(function (pair) {
      var part = pair[0];
      var old = keyed(part);
      Object.keys(old).forEach(function (id) {
        before[id] = old[id].getBoundingClientRect();
        html[id] = old[id].outerHTML;
      });
      // panourile „i” și „Arată celelalte alerte” rămân deschise după înlocuire
      part.querySelectorAll("details[open]").forEach(function (d) {
        var anchor = anchorOf(d, part);
        var holder = document.getElementById(anchor);
        openDetails.push([anchor, Array.prototype.indexOf.call(holder.querySelectorAll("details"), d)]);
      });
      if (active && part.contains(active)) {
        var anchor = anchorOf(active, part);
        var all = document.getElementById(anchor).querySelectorAll("a, button, summary, input");
        focus = [anchor, Array.prototype.indexOf.call(all, active)];
      }
    });

    pairs.forEach(function (pair) {
      var part = pair[0];
      part.replaceChildren.apply(part, Array.prototype.slice.call(pair[1].childNodes).map(function (n) {
        return document.importNode(n, true);
      }));
    });

    openDetails.forEach(function (entry) {
      var holder = document.getElementById(entry[0]);
      var d = holder && holder.querySelectorAll("details")[entry[1]];
      if (d) d.open = true;
    });
    if (focus) {
      var holder = document.getElementById(focus[0]);
      var target = holder && holder.querySelectorAll("a, button, summary, input")[focus[1]];
      if (target) target.focus({ preventScroll: true });
    }

    pairs.forEach(function (pair) {
      var now = keyed(pair[0]);
      Object.keys(now).forEach(function (id) {
        var el = now[id];
        if (!(id in before)) { enter(el); return; }
        var from = before[id];
        var to = el.getBoundingClientRect();
        var dx = from.left - to.left;
        var dy = from.top - to.top;
        var edited = html[id] !== el.outerHTML;
        if (Math.abs(dx) > 1 || Math.abs(dy) > 1) move(el, dx, dy, edited);
        else if (edited) enter(el);
      });
    });
  }

  // cardul care și-a schimbat locul pornește de unde era și alunecă în locul nou (FLIP); fără mișcare cu Reduce Motion.
  // Conturul rămâne doar pe ce s-a schimbat, nu și pe vecinii împinși din loc.
  function move(el, dx, dy, edited) {
    if (!el.animate) return;
    if (reduce.matches) {
      if (edited) el.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 200, easing: "linear" });
    } else {
      el.animate(
        [{ transform: "translate(" + dx + "px, " + dy + "px)" }, { transform: "none" }],
        { duration: 450, easing: "cubic-bezier(0.25, 1, 0.5, 1)" }
      );
    }
    if (edited) mark(el);
  }

  function enter(el) {
    if (el.animate) {
      var frames = reduce.matches
        ? [{ opacity: 0 }, { opacity: 1 }]
        : [{ opacity: 0, transform: "translateY(0.375rem)" }, { opacity: 1, transform: "none" }];
      el.animate(frames, { duration: reduce.matches ? 200 : 350, easing: "cubic-bezier(0.25, 1, 0.5, 1)" });
    }
    mark(el);
  }

  // un contur scurt pe ce s-a schimbat, ca privirea să găsească noutatea pe ecranul proiectat
  function mark(el) {
    el.classList.add("is-live-updated");
    setTimeout(function () { el.classList.remove("is-live-updated"); }, 2000);
  }

  function updateGraph(doc) {
    var current = document.getElementById("graph-data");
    var next = doc.getElementById("graph-data");
    if (!current || !next || current.textContent === next.textContent) return;
    current.textContent = next.textContent;
    document.dispatchEvent(new CustomEvent("pg:graph", { detail: JSON.parse(next.textContent) }));
  }

  // ---------------------------------------------------------------- sursa: SSE, cu polling ca rezervă

  function startPolling() {
    if (pollTimer) return;
    pollTimer = setInterval(refresh, POLL_MS);
  }

  function stopPolling() {
    if (!pollTimer) return;
    clearInterval(pollTimer);
    pollTimer = null;
  }

  function connect() {
    if (!window.EventSource) { startPolling(); return; }
    source = new EventSource(main.getAttribute("data-live"));
    source.addEventListener("feed", function () { schedule(); });
    source.addEventListener("reset", function () { schedule(); });
    // după o întrerupere, ce s-a întâmplat între timp vine prin Last-Event-ID; polling-ul nu mai e nevoie
    source.addEventListener("open", stopPolling);
    source.addEventListener("error", function () {
      startPolling();
      if (source.readyState === EventSource.CLOSED) source = null;
    });
  }

  document.addEventListener("click", function (event) {
    if (event.target.closest("[data-live-retry]")) refresh();
  });

  // un tab ascuns nu ține o conexiune deschisă; la revenire se reîmprospătează o dată
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) {
      if (source) { source.close(); source = null; }
      stopPolling();
    } else {
      connect();
      schedule(0);
    }
  });

  connect();
})();
