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

  // conturul numelor din graf ia culoarea cadrului (alb în fișă), nu fundalul aplicației
  function halo() {
    var frame = container.closest(".graph-frame") || container;
    var color = window.getComputedStyle(frame).backgroundColor;
    return color && !/rgba\(\s*0,\s*0,\s*0,\s*0\s*\)|transparent/.test(color) ? color : null;
  }

  // legenda substanțelor numerotate din graf (pgLegend din graph-core.js), sub cadru; textul intră cu textContent
  var legendEl = document.getElementById("graph-legend");
  function renderLegend(elements) {
    if (!legendEl || typeof window.pgLegend !== "function") return;
    var items = window.pgLegend(elements);
    legendEl.textContent = "";
    items.forEach(function (item) {
      var li = document.createElement("li");
      var num = document.createElement("span");
      num.className = "graph-legend-num" + (item.severity ? " sev-" + item.severity : "");
      num.textContent = String(item.num);
      num.setAttribute("aria-hidden", "true");
      var text = document.createElement("span");
      var name = document.createElement("strong");
      name.textContent = item.label;
      text.appendChild(name);
      var detail = [];
      if (item.products.length) detail.push("din " + item.products.join(", "));
      if (item.classes.length) detail.push(item.classes[0]);
      if (detail.length) {
        var small = document.createElement("span");
        small.className = "graph-legend-detail";
        small.textContent = detail.join(" · ");
        text.appendChild(small);
      }
      li.setAttribute("aria-label", "Cercul " + item.num + ": " + item.label + (detail.length ? ", " + detail.join(", ") : ""));
      li.appendChild(num);
      li.appendChild(text);
      legendEl.appendChild(li);
    });
    legendEl.hidden = items.length === 0;
  }

  function mount(elements) {
    return window.pgMount(container, elements, {
      dark: dark.matches,
      contrast: contrast.matches,
      // în fișă graful nu fură derularea paginii
      interactive: !page,
      halo: halo,
      onAlert: function (id) { open("alert", id); },
      onMed: function (id) { open("med", id); },
      onReady: function (count) { post("ready", count); },
    });
  }

  var graph = mount(data);
  renderLegend(data);

  // QA5.1: fișa s-a actualizat singură (live.js) și graful are date noi
  document.addEventListener("pg:graph", function (event) {
    graph.destroy();
    graph = mount(event.detail);
    renderLegend(event.detail);
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
