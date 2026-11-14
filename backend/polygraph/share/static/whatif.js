// PolyGraph · „Dacă prescriu…” pe fișa pacientului (QA5.2). Trimite numele la /portal/patients/{id}/what-if și pune
// sub câmp fragmentul primit (aceleași carduri ca în fișă). Textele stărilor sunt în pagină, în <template>.
(function () {
  "use strict";

  var form = document.querySelector("[data-whatif]");
  if (!form || !window.fetch) return;

  var input = form.querySelector("input[name=query]");
  var result = document.querySelector("[data-whatif-result]");
  var section = form.closest("section");
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  var last = "";
  var pending = null;

  function show(nodes) {
    result.replaceChildren.apply(result, nodes);
    var first = result.firstElementChild;
    if (first && first.animate) {
      first.animate(
        reduce.matches ? [{ opacity: 0 }, { opacity: 1 }] : [{ opacity: 0, transform: "translateY(0.375rem)" }, { opacity: 1, transform: "none" }],
        { duration: reduce.matches ? 160 : 300, easing: "cubic-bezier(0.25, 1, 0.5, 1)" }
      );
    }
  }

  function fromTemplate(selector) {
    var tpl = section.querySelector(selector);
    return tpl ? [tpl.content.cloneNode(true)] : [];
  }

  function check(query) {
    last = query;
    if (pending) pending.abort();
    var controller = window.AbortController ? new AbortController() : null;
    pending = controller;
    // butonul rămâne activ: o căutare nouă o anulează pe cea în curs
    result.setAttribute("aria-busy", "true");
    show(fromTemplate("[data-whatif-loading]"));

    fetch(form.action, {
      method: "POST",
      body: new URLSearchParams({ query: query }),
      credentials: "same-origin",
      headers: { Accept: "text/html" },
      signal: controller ? controller.signal : undefined,
    })
      .then(function (response) {
        // sesiunea a expirat sau pacientul nu mai e în listă: pagina întreagă spune de ce
        if (response.status === 401 || response.status === 404) { window.location.reload(); return null; }
        if (!response.ok) throw new Error("server");
        return response.text();
      })
      .then(function (html) {
        if (html === null) return;
        var doc = new DOMParser().parseFromString(html, "text/html");
        show(Array.prototype.slice.call(doc.body.childNodes).map(function (n) { return document.importNode(n, true); }));
      })
      .catch(function (err) {
        if (err && err.name === "AbortError") return;
        show(fromTemplate(err && err.message === "server" ? '[data-whatif-error="server"]' : '[data-whatif-error="network"]'));
      })
      .then(function () {
        if (pending !== controller) return;
        pending = null;
        result.removeAttribute("aria-busy");
      });
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    check(input.value.trim());
  });

  result.addEventListener("click", function (event) {
    if (event.target.closest("[data-whatif-retry]")) check(last);
  });
})();
