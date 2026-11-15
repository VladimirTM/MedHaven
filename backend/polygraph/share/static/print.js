// PolyGraph · lista completă a medicamentelor: împarte conținutul în pagini A4 și pune numărul paginii în subsol.
// Browserele nu pot numerota singure paginile la tipărire (Safari nu suportă @page margin boxes), așa că paginile
// sunt făcute aici, iar ce se vede pe ecran e exact ce se tipărește. Fără JavaScript, foaia rămâne o singură pagină lungă.
(function () {
  "use strict";

  var sheet = document.querySelector("[data-sheet]");
  if (!sheet) return;

  // loc de siguranță sub pagină (4 mm): dacă tipărirea măsoară textul puțin altfel decât ecranul, nimic nu iese din pagină
  var SAFE = 4 * 96 / 25.4;

  // blocurile din foaie, în ordine; tabelele sunt împărțite pe rânduri, secțiunea de semnătură rămâne întreagă
  function collect() {
    var out = [];
    Array.prototype.forEach.call(sheet.children, function (block) {
      if (block.tagName === "SECTION" && !block.classList.contains("signature")) {
        Array.prototype.forEach.call(block.children, function (el) {
          if (el.tagName === "TABLE") {
            Array.prototype.forEach.call(el.querySelectorAll("tbody tr"), function (tr) {
              out.push({ row: tr, table: el, keep: tr.classList.contains("group") });
            });
          } else {
            out.push({ el: el, keep: el.tagName === "H2" });
          }
        });
      } else {
        out.push({ el: block, keep: false });
      }
    });
    return out;
  }

  function build() {
    var units = collect();
    var container = document.createElement("div");
    container.className = "pages";
    sheet.appendChild(container);

    var pages = [];
    var body = null;      // corpul paginii curente
    var placed = [];      // unitățile din pagina curentă
    var shell = null;     // tabelul curent (o bucată din tabelul original, cu antetul repetat)
    var started = new Set();

    function newPage() {
      var pg = document.createElement("div");
      pg.className = "pg";
      body = document.createElement("div");
      body.className = "pg-body";
      var foot = document.createElement("div");
      foot.className = "pg-foot";
      pg.appendChild(body);
      pg.appendChild(foot);
      container.appendChild(pg);
      pages.push(foot);
      placed = [];
      shell = null;
    }

    function makeShell(table) {
      var t = table.cloneNode(false);
      var cg = table.querySelector("colgroup");
      if (cg) t.appendChild(cg.cloneNode(true));
      var hasCaption = false;
      if (table.caption && !started.has(table)) {
        t.appendChild(table.caption.cloneNode(true));
        started.add(table);
        hasCaption = true;
      }
      if (table.tHead) t.appendChild(table.tHead.cloneNode(true));
      var tb = document.createElement("tbody");
      t.appendChild(tb);
      body.appendChild(t);
      return { table: t, tbody: tb, src: table, hasCaption: hasCaption };
    }

    function place(u) {
      if (u.row) {
        if (!shell || shell.src !== u.table) shell = makeShell(u.table);
        u.shell = shell;
        shell.tbody.appendChild(u.row);
      } else {
        shell = null;
        body.appendChild(u.el);
      }
      placed.push(u);
    }

    function remove(u) {
      var node = u.row || u.el;
      node.remove();
      if (u.shell && !u.shell.tbody.children.length) {
        u.shell.table.remove();
        if (u.shell.hasCaption) started.delete(u.shell.src);
        if (shell === u.shell) shell = null;
      }
    }

    function overflows() {
      return body.scrollHeight > body.clientHeight - SAFE;
    }

    newPage();
    units.forEach(function (u) {
      place(u);
      if (!overflows() || placed.length === 1) return;
      // nu încape: iese din pagina curentă, împreună cu titlurile care îi aparțin (titlul unei secțiuni, grupul din tabel)
      remove(placed.pop());
      var carry = [];
      while (placed.length > 1 && placed[placed.length - 1].keep) {
        var k = placed.pop();
        remove(k);
        carry.unshift(k);
      }
      newPage();
      carry.forEach(place);
      place(u);
    });

    pages.forEach(function (foot, i) {
      foot.textContent = "Pagina " + (i + 1) + " din " + pages.length;
    });

    // ce a rămas din foaia originală (secțiunile goale) iese; rămân doar paginile
    Array.prototype.slice.call(sheet.children).forEach(function (c) {
      if (c !== container) c.remove();
    });
    sheet.classList.add("paginated");
  }

  build();
})();
