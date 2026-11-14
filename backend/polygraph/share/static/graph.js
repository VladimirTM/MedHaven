// PolyGraph · graful terapeutic în portalul medicului de familie (B6). Desenul e în graph-core.js, același cu cel
// din aplicație (QA2); aici doar se citesc datele din pagină, tema din matchMedia și ce înseamnă o atingere.
(function () {
  "use strict";

  var container = document.getElementById("graph");
  var dataEl = document.getElementById("graph-data");
  if (!container || !dataEl || typeof window.pgMount !== "function" || typeof cytoscape !== "function") return;

  var data = JSON.parse(dataEl.textContent);
  var embed = document.body.classList.contains("embed");
  var page = document.body.classList.contains("page");
  var dark = window.matchMedia("(prefers-color-scheme: dark)");
  var contrast = window.matchMedia("(prefers-contrast: more)");

  function post(name, value) {
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name];
    if (handler) handler.postMessage(value);
    return !!handler;
  }

  // în WKWebView atingerea merge la aplicație; în fișă, la cardul de mai sus; pe pagina grafului, înapoi în fișă
  function open(kind, id) {
    if (post(kind, id) || embed) return;
    if (page) document.dispatchEvent(new CustomEvent("pg:" + kind, { detail: id }));
    else window.location.href = window.location.pathname.replace(/\/graph$/, "") + "#" + kind + "-" + id;
  }

  function theme() { return { dark: dark.matches, contrast: contrast.matches }; }

  var graph = window.pgMount(container, data, {
    dark: dark.matches,
    contrast: contrast.matches,
    // în fișă graful nu fură derularea paginii
    interactive: !page,
    onAlert: function (id) { open("alert", id); },
    onMed: function (id) { open("med", id); },
    onReady: function (count) { post("ready", count); },
  });

  [dark, contrast].forEach(function (mq) {
    if (mq.addEventListener) mq.addEventListener("change", function () { graph.setTheme(theme()); });
  });
  window.addEventListener("resize", function () { graph.resize(); });

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  document.querySelectorAll("[data-graph-reset]").forEach(function (button) {
    button.addEventListener("click", function () { graph.reset(!reduce.matches); });
  });
  window.pgResetView = function (animated) { graph.reset(animated); };
})();
