// PolyGraph · portalul medicului de familie (B6, QA4): antetul la derulare, decizia pe alertă (inclusiv schimbarea ei) și copierea adresei.
(function () {
  "use strict";

  // gradientul de sub antet apare doar după ce pagina a fost derulată
  var bar = document.querySelector("[data-topbar]");
  var sentinel = document.querySelector(".scroll-sentinel");
  if (bar && sentinel && "IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      bar.classList.toggle("is-scrolled", !entries[0].isIntersecting);
    }).observe(sentinel);
  }

  function formatNow() {
    var d = new Date();
    var p = function (n) { return String(n).padStart(2, "0"); };
    return p(d.getHours()) + ":" + p(d.getMinutes());
  }

  var LABEL = { keep: "Menține", change_at_visit: "Modific la consultație", refer_specialist: "Trimit la specialist" };

  function syncSelection(form, decision) {
    form.dataset.currentDecision = decision || "";
    form.querySelectorAll(".decisions button[name=decision]").forEach(function (btn) {
      btn.classList.toggle("is-selected", btn.value === decision);
    });
    form.querySelectorAll('.decision-segment [role="radio"]').forEach(function (radio) {
      var active = radio.getAttribute("data-decision") === decision;
      radio.classList.toggle("is-selected", active);
      radio.setAttribute("aria-checked", active ? "true" : "false");
    });
  }

  // QA-14: Enter în notă nu trimite formularul; cere alegerea unei decizii mai jos
  document.addEventListener("keydown", function (event) {
    if (event.key !== "Enter") return;
    var input = event.target.closest(".note-input");
    if (!input) return;
    event.preventDefault();
    var form = input.closest(".review-form");
    var hint = form && form.querySelector(".note-hint");
    if (hint) hint.hidden = false;
  });

  // controlul segmentat (< 600 px) și butonul „Schimbă” + „Copiază”
  document.addEventListener("click", function (event) {
    var radio = event.target.closest('.decision-segment [role="radio"]');
    if (radio) {
      var form = radio.closest(".review-form");
      if (form) {
        syncSelection(form, radio.getAttribute("data-decision"));
        var hint = form.querySelector(".note-hint");
        if (hint) hint.hidden = true;
      }
      return;
    }

    var changeBtn = event.target.closest("[data-change-review]");
    if (changeBtn) {
      var review = changeBtn.closest(".review");
      if (!review) return;
      var wrap = review.querySelector(".reviewed-wrap");
      var reviewForm = review.querySelector(".review-form");
      if (wrap) wrap.hidden = true;
      if (reviewForm) {
        syncSelection(reviewForm, reviewForm.dataset.currentDecision || "");
        reviewForm.hidden = false;
      }
      return;
    }

    var copyBtn = event.target.closest("[data-copy]");
    if (copyBtn) {
      var value = copyBtn.getAttribute("data-copy") || "";
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).catch(function () {});
      }
      copyBtn.textContent = "Copiat";
      setTimeout(function () { copyBtn.textContent = "Copiază"; }, 2000);
    }
  });

  document.addEventListener("submit", function (event) {
    var form = event.target.closest(".review-form");
    if (!form) return;
    event.preventDefault();
    if (form.dataset.busy) return;

    var submitter = event.submitter;
    var decision = (submitter && submitter.name === "decision" && submitter.value) || form.dataset.currentDecision || "";
    var hint = form.querySelector(".note-hint");
    if (!decision) {
      if (hint) hint.hidden = false;
      return;
    }
    if (hint) hint.hidden = true;

    var buttons = form.querySelectorAll("button");
    var error = form.querySelector(".review-error");
    var noteInput = form.querySelector("input[name=note]");
    var note = noteInput ? noteInput.value.trim() : "";
    form.dataset.busy = "1";
    buttons.forEach(function (b) { b.disabled = true; });
    error.hidden = true;

    fetch(form.action, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ decision: decision, note: note }),
      credentials: "same-origin",
    })
      .then(function (response) {
        if (response.status === 401) throw new Error("session");
        if (!response.ok) throw new Error("server");
        return response.json();
      })
      .then(function () {
        delete form.dataset.busy;
        buttons.forEach(function (b) { b.disabled = false; });
        syncSelection(form, decision);
        var review = form.closest(".review");
        var wrap = review && review.querySelector(".reviewed-wrap");
        if (wrap) {
          var state = document.createElement("p");
          state.className = "reviewed-state";
          state.setAttribute("role", "status");
          var summary = document.createElement("span");
          summary.className = "reviewed-summary";
          summary.textContent = LABEL[decision] + " · acum (" + formatNow() + ")";
          state.appendChild(summary);
          state.appendChild(document.createTextNode(" "));
          var change = document.createElement("button");
          change.className = "btn btn-secondary change-decision";
          change.type = "button";
          change.setAttribute("data-change-review", "");
          change.textContent = "Schimbă";
          state.appendChild(change);
          if (note) {
            var noteEl = document.createElement("span");
            noteEl.className = "note";
            noteEl.textContent = "„" + note + "”";
            state.appendChild(document.createElement("br"));
            state.appendChild(noteEl);
          }
          wrap.replaceChildren(state);
          wrap.hidden = false;
        }
        var card = form.closest(".alert");
        if (card) card.classList.add("is-reviewed");
        form.hidden = true;
      })
      .catch(function (err) {
        if (err && err.message === "session") {
          error.textContent = "Sesiunea a expirat. Reîncărcați pagina și autentificați-vă din nou.";
        } else if (err && err.message === "server") {
          error.textContent = "Nu s-a putut salva. Încercați din nou.";
        } else {
          error.textContent = "Nu s-a putut salva. Verificați conexiunea.";
        }
        error.hidden = false;
        delete form.dataset.busy;
        buttons.forEach(function (b) { b.disabled = false; });
      });
  });

  // explicațiile din rezumat sunt popover-e: se închid la o atingere în afara lor sau cu Escape
  function closeStats(except) {
    document.querySelectorAll(".stat details.info[open]").forEach(function (d) {
      if (d !== except) d.open = false;
    });
  }
  document.addEventListener("click", function (event) {
    closeStats(event.target.closest(".stat details.info"));
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closeStats(null);
  });

  // tap pe o muchie din graf → alerta corespunzătoare (graph.js trimite evenimentul)
  document.addEventListener("pg:alert", function (event) {
    var card = document.getElementById("alert-" + event.detail);
    if (!card) return;
    // alertele moderate stau strânse sub „Arată…”; deschidem lista și detaliile alertei
    var more = card.closest("details.more");
    if (more) more.open = true;
    var info = card.querySelector("details.info");
    if (info) info.open = true;
    var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    card.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
    document.querySelectorAll(".alert.is-highlighted").forEach(function (el) { el.classList.remove("is-highlighted"); });
    card.classList.add("is-highlighted");
  });

  // „Tipăriți sau salvați PDF” pe fișa pentru consultație: dialogul de tipărire al browserului (are și „Salvează ca PDF”)
  document.addEventListener("click", function (event) {
    if (event.target.closest("[data-print]")) window.print();
  });

  // tap pe un medicament din graf → cardul lui din lista „Medicamente”
  document.addEventListener("pg:med", function (event) {
    var card = document.getElementById("med-" + event.detail);
    if (!card) return;
    var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    card.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "center" });
    document.querySelectorAll(".med.is-highlighted").forEach(function (el) { el.classList.remove("is-highlighted"); });
    card.classList.add("is-highlighted");
  });
})();
