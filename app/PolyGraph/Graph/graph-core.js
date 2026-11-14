// PolyGraph · graful terapeutic, un singur renderer pentru aplicație și portal (QA2).
// Sursa e backend/polygraph/share/static/graph-core.js; app/PolyGraph/Graph/graph-core.js e o copie identică
// (aplicația merge offline), verificată byte cu byte de backend/tests/test_graph_core.py.
// Fără dependențe de WKWebView sau de pagină: primește containerul, graful (contracts/schema/graph.schema.json)
// și callback-urile; cine îl folosește decide ce înseamnă o atingere.
//
//   const graph = pgMount(container, graph, { dark, contrast, interactive, onAlert, onMed, onReady });
//   graph.reset(animated)            // „Recentrează”: tot graful, centrat
//   graph.setTheme({ dark, contrast })
//   graph.destroy()
(function () {
  "use strict";

  // Layout radial determinist: pacientul în centru; medicamentele pe primul inel, ordonate astfel încât
  // perechile care interacționează să fie apropiate (mai puține linii care traversează desenul); fiecare
  // substanță pe aceeași rază cu medicamentul ei; clasele, alimentele și simptomele în afară, în direcția
  // substanțelor de care țin. Inelele sunt elipse, ca desenul să umple ecranul pe înălțime.
  function pgRadialPositions(cy, W, H) {
    const TAU = Math.PI * 2;
    const products = cy.nodes('[type = "product"]').map((n) => n.id()).sort();
    const productOf = {};
    cy.edges('[type = "contains"]').forEach((e) => { productOf[e.data("target")] = e.data("source"); });
    const sevWeight = { critical: 6, major: 6, moderate: 2, minor: 1, unknown: 0.5 };
    const pairs = [];
    cy.edges('[type = "interacts"]').forEach((e) => {
      const a = productOf[e.data("source")], b = productOf[e.data("target")];
      if (a && b && a !== b) pairs.push([a, b, sevWeight[e.data("severity")] || 1]);
    });

    // ordinea pe cerc: căutare locală prin schimburi, pornind de la ordinea alfabetică (id-uri)
    const n = products.length;
    function cost(order) {
      const at = {}; order.forEach((id, i) => { at[id] = i; });
      let c = 0;
      for (const [a, b, w] of pairs) { const d = Math.abs(at[a] - at[b]); c += w * Math.min(d, n - d); }
      for (let i = 0; i < pairs.length; i++) {
        for (let j = i + 1; j < pairs.length; j++) {
          let [a, b] = [at[pairs[i][0]], at[pairs[i][1]]]; if (a > b) [a, b] = [b, a];
          const c1 = at[pairs[j][0]], c2 = at[pairs[j][1]];
          if (c1 === a || c1 === b || c2 === a || c2 === b) continue;
          if ((c1 > a && c1 < b) !== (c2 > a && c2 < b)) c += 1.5;
        }
      }
      return c;
    }
    let order = products.slice(), best = cost(order), improved = true;
    if (n >= 4 && n <= 8) {
      // până la 8 medicamente: toate ordinile, cu primul fixat (rotațiile dau același desen)
      const rest = products.slice(1), used = new Array(rest.length).fill(false), current = [products[0]];
      (function permute() {
        if (current.length === n) { const c = cost(current); if (c < best - 1e-9) { best = c; order = current.slice(); } return; }
        for (let i = 0; i < rest.length; i++) {
          if (used[i]) continue;
          used[i] = true; current.push(rest[i]); permute(); current.pop(); used[i] = false;
        }
      })();
      improved = false;
    }
    while (improved) {
      improved = false;
      for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) {
        const next = order.slice(); [next[i], next[j]] = [next[j], next[i]];
        const c = cost(next); if (c < best - 1e-9) { best = c; order = next; improved = true; }
      }
    }

    const angle = {};
    order.forEach((id, i) => { angle[id] = -Math.PI / 2 + (i * TAU) / Math.max(n, 1); });
    const meanAngle = (list) => {
      let x = 0, y = 0; list.forEach((a) => { x += Math.cos(a); y += Math.sin(a); });
      return Math.atan2(y, x);
    };
    // substanțele: pe raza medicamentului; mai multe substanțe se desfac puțin în jurul ei
    const byProduct = {};
    Object.keys(productOf).sort().forEach((s) => { (byProduct[productOf[s]] = byProduct[productOf[s]] || []).push(s); });
    const spread = (TAU / Math.max(n, 1)) * 0.75;
    for (const [p, subs] of Object.entries(byProduct)) {
      subs.forEach((s, i) => { angle[s] = angle[p] + (subs.length === 1 ? 0 : spread * (i / (subs.length - 1) - 0.5)); });
    }
    // inelul exterior: direcția medie a substanțelor (sau medicamentelor) de care ține nodul
    const outer = cy.nodes('[type = "atc_class"], [type = "food"], [type = "symptom"]');
    outer.forEach((node) => {
      const linked = node.connectedEdges().connectedNodes().filter((m) => m.id() !== node.id() && angle[m.id()] !== undefined);
      angle[node.id()] = linked.length ? meanAngle(linked.map((m) => angle[m.id()])) : 0;
    });
    // pe fiecare inel, nodurile care ar cădea unul peste altul se împing la o distanță minimă
    function separate(ids, minGap) {
      if (ids.length < 2) return;
      const gap = Math.min(minGap, TAU / ids.length);
      const items = ids.map((id) => ({ id, a: ((angle[id] % TAU) + TAU) % TAU })).sort((p, q) => p.a - q.a || (p.id < q.id ? -1 : 1));
      for (let pass = 0; pass < 4; pass++) {
        for (let i = 1; i < items.length; i++) if (items[i].a - items[i - 1].a < gap) items[i].a = items[i - 1].a + gap;
        const wrap = items[0].a + TAU - items[items.length - 1].a;
        if (wrap < gap) items.forEach((it, i) => { it.a -= (gap - wrap) * (i / items.length); });
      }
      items.forEach((it) => { angle[it.id] = it.a; });
    }
    separate(Object.keys(productOf), TAU / 22);
    separate(cy.nodes('[type = "atc_class"]').map((m) => m.id()), TAU / 22);
    separate(cy.nodes('[type = "food"], [type = "symptom"]').map((m) => m.id()), TAU / 14);

    const rx = W / 2, ry = Math.min(H / 2, rx * 1.45);
    const ring = { product: 0.5, substance: 0.72, atc_class: 0.88, food: 1.02, symptom: 1.02 };
    const positions = {};
    cy.nodes().forEach((node) => {
      const type = node.data("type");
      if (type === "patient") { positions[node.id()] = { x: 0, y: 0 }; return; }
      const r = ring[type] || 1.0, a = angle[node.id()] || 0;
      positions[node.id()] = { x: Math.cos(a) * rx * r, y: Math.sin(a) * ry * r };
      // etichetele de pe inelele exterioare stau spre exterior, nu peste linii
      if (type === "food" || type === "symptom") {
        const c = Math.cos(a), s = Math.sin(a);
        node.data("lh", c > 0.4 ? "right" : c < -0.4 ? "left" : "center");
        node.data("lv", Math.abs(c) > 0.4 ? "center" : s < 0 ? "top" : "bottom");
      }
    });
    return positions;
  }

  // Culorile de sistem iOS și accentul din Assets.xcassets, scrise ca hex / rgba: Cytoscape nu înțelege
  // variabilele CSS și nici sintaxa `rgb(0 0 0 / 0.1)` (QA-01).
  function palette(dark, contrast) {
    const p = dark
      ? {
          text: "#F2F2F7", muted: "#8E8E93", faint: "rgba(235,235,245,0.18)", node: "#2C2C2E", nodeBorder: "#48484A",
          accent: "#5CC2BC", red: "#FF453A", orange: "#FF9F0A", gray: "#636366", purple: "#BF5AF2", green: "#30D158",
        }
      : {
          text: "#1C1C1E", muted: "#8E8E93", faint: "rgba(60,60,67,0.18)", node: "#FFFFFF", nodeBorder: "#D1D1D6",
          accent: "#0E6B68", red: "#FF3B30", orange: "#FF9500", gray: "#AEAEB2", purple: "#AF52DE", green: "#34C759",
        };
    if (contrast) {
      p.muted = dark ? "#AEAEB2" : "#6C6C70";
      p.faint = dark ? "rgba(235,235,245,0.45)" : "rgba(60,60,67,0.45)";
      p.nodeBorder = dark ? "#8E8E93" : "#6C6C70";
    }
    p.moderateOpacity = contrast ? 0.7 : 0.4;
    return p;
  }

  function severityColor(p, s) {
    switch (s) {
      case "critical": case "major": return p.red;
      case "moderate": return p.orange;
      default: return p.gray;
    }
  }

  // eticheta clasei ATC (9 px) apare doar de la zoom 1.5 în sus: 9 × 1.5 = 13.5 px pe ecran (Q3-12)
  const ATC_LABEL_ZOOM = 1.5;

  function style(p) {
    return [
      { selector: "node", style: {
          "label": "data(label)", "color": p.text, "font-family": "-apple-system, system-ui, \"Segoe UI\", Roboto, sans-serif",
          "font-size": 11, "text-valign": "bottom", "text-margin-y": 4,
          "text-wrap": "wrap", "text-max-width": 90,
          "background-color": p.node, "border-width": 1.5, "border-color": p.nodeBorder,
          "width": 18, "height": 18 } },
      { selector: 'node[type = "patient"]', style: {
          "background-color": p.accent, "border-width": 0, "width": 34, "height": 34,
          "font-size": 13, "font-weight": 600 } },
      { selector: 'node[type = "product"]', style: {
          "shape": "round-rectangle", "width": 26, "height": 26, "font-size": 12, "font-weight": 600,
          "border-color": p.accent, "border-width": 2 } },
      { selector: 'node[type = "product"][severity = "critical"], node[type = "product"][severity = "major"]',
        style: { "border-color": p.red } },
      { selector: 'node[type = "product"][severity = "moderate"]', style: { "border-color": p.orange } },
      { selector: 'node[type = "substance"]', style: {
          "width": 12, "height": 12, "font-size": 10, "color": p.muted, "text-max-width": 70,
          "min-zoomed-font-size": 7 } },
      { selector: 'node[type = "atc_class"]', style: {
          "shape": "diamond", "width": 10, "height": 10, "font-size": 9, "color": p.muted,
          "min-zoomed-font-size": 9 * ATC_LABEL_ZOOM } },
      { selector: 'node[type = "food"]', style: {
          "shape": "round-tag", "width": 14, "height": 14, "border-color": p.green, "font-size": 10 } },
      { selector: 'node[type = "symptom"]', style: {
          "shape": "star", "width": 16, "height": 16, "border-color": p.purple, "font-size": 10 } },
      { selector: "node[lh]", style: { "text-halign": "data(lh)", "text-valign": "data(lv)", "text-margin-y": 0 } },
      { selector: 'node[lh = "left"]', style: { "text-margin-x": -4 } },
      { selector: 'node[lh = "right"]', style: { "text-margin-x": 4 } },
      { selector: 'node[lv = "top"]', style: { "text-margin-y": -4 } },
      { selector: 'node[lv = "bottom"]', style: { "text-margin-y": 4 } },

      { selector: "edge", style: {
          "width": 1, "line-color": p.faint, "curve-style": "bezier", "target-arrow-shape": "none" } },
      { selector: 'edge[type = "in_class"]', style: { "line-style": "dotted" } },
      { selector: 'edge[type = "interacts"], edge[type = "food_interaction"]', style: {
          "width": 1.5, "line-color": (e) => severityColor(p, e.data("severity")), "z-index": 10 } },
      // ce e grav se vede primul (Q3-12): moderatele subțiri și transparente, gravele groase și deasupra
      { selector: 'edge[severity = "moderate"]', style: { "width": 1.5, "opacity": p.moderateOpacity } },
      { selector: 'edge[severity = "critical"], edge[severity = "major"]', style: { "width": 4, "z-index": 20 } },
      { selector: 'edge[type = "food_interaction"]', style: { "line-style": "dashed" } },
      { selector: 'edge[severity = "unknown"]', style: { "line-style": "dashed", "width": 1, "line-color": p.gray } },
      { selector: 'edge[type = "possibly_related"], edge[type = "reported"]', style: {
          "line-style": "dashed", "line-color": p.purple, "width": 1.5 } },
      { selector: "edge[alert_id]", style: { "overlay-padding": 10 } },
      { selector: ":selected", style: { "overlay-opacity": 0.12, "overlay-color": p.accent } },
    ];
  }

  const PADDING = 24;
  const FOCUS_PADDING = 48;
  const RANK = { critical: 0, major: 1, moderate: 2, minor: 3, info: 4 };

  // nodurile alertei celei mai grave (critical / major): capetele muchiei și medicamentele din care vin;
  // la egalitate, prima din listă (alertele vin deja ordonate de backend)
  function worstAlert(cy) {
    let best = null;
    cy.edges("[alert_id]").forEach((e) => {
      const r = RANK[e.data("severity")];
      if (r !== undefined && r <= RANK.major && (!best || r < best.r)) best = { id: e.data("alert_id"), r };
    });
    if (!best) return null;
    const edges = cy.edges().filter((e) => e.data("alert_id") === best.id);
    const ends = edges.connectedNodes();
    return edges.union(ends).union(ends.incomers('node[type = "product"]'));
  }

  function pgMount(container, graph, options) {
    const opts = options || {};
    let theme = { dark: !!opts.dark, contrast: !!opts.contrast };
    const interactive = opts.interactive !== false;
    const cy = cytoscape({
      container: container || undefined,
      styleEnabled: true,
      elements: graph,
      style: style(palette(theme.dark, theme.contrast)),
      layout: { name: "null" },
      minZoom: 0.3, maxZoom: 4,
      userZoomingEnabled: interactive, userPanningEnabled: interactive,
      boxSelectionEnabled: false, autoungrabify: true,
    });
    const W = Math.max(((container && container.clientWidth) || opts.width || window.innerWidth || 390) - 60, 200);
    const H = Math.max(((container && container.clientHeight) || opts.height || window.innerHeight || 640) - 60, 200);
    const positions = pgRadialPositions(cy, W, H);
    cy.layout({ name: "preset", positions: (n) => positions[n.id()], fit: false, animate: false }).run();

    const focus = worstAlert(cy);
    let showingAll = !focus;
    function viewport(eles, pad) {
      if (container) { cy.fit(eles, pad); return; }
      const vw = opts.width || 390, vh = opts.height || 640;
      const bb = (eles || cy.elements()).boundingBox({ includeLabels: false });
      const z = Math.max(0.3, Math.min(4, (vw - pad * 2) / Math.max(bb.w, 1), (vh - pad * 2) / Math.max(bb.h, 1)));
      cy.zoom(z);
      cy.pan({ x: vw / 2 - ((bb.x1 + bb.x2) / 2) * z, y: vh / 2 - ((bb.y1 + bb.y2) / 2) * z });
    }
    function showFocus() {
      viewport(focus, FOCUS_PADDING);
      // sub zoom-ul la care apar etichetele claselor, ca ele să nu acopere medicamentele
      if (cy.zoom() > ATC_LABEL_ZOOM - 0.1) {
        cy.zoom(ATC_LABEL_ZOOM - 0.1);
        if (container) cy.center(focus);
        else {
          const vw = opts.width || 390, vh = opts.height || 640, bb = focus.boundingBox({ includeLabels: false }), z = cy.zoom();
          cy.pan({ x: vw / 2 - ((bb.x1 + bb.x2) / 2) * z, y: vh / 2 - ((bb.y1 + bb.y2) / 2) * z });
        }
      }
    }
    function showAll(animated) {
      showingAll = true;
      if (animated && container) cy.animate({ fit: { padding: PADDING } }, { duration: 300, easing: "ease-out-cubic" });
      else viewport(undefined, PADDING);
    }
    if (showingAll) showAll(false); else showFocus();

    cy.on("tap", "edge", (event) => {
      const id = event.target.data("alert_id");
      if (id && opts.onAlert) opts.onAlert(id);
    });
    cy.on("tap", 'node[type = "product"]', (event) => { if (opts.onMed) opts.onMed(event.target.id()); });
    if (opts.onReady) opts.onReady(cy.nodes().length);

    return {
      cy: cy,
      reset: (animated) => showAll(!!animated),
      resize: () => {
        cy.resize();
        if (showingAll) cy.fit(undefined, PADDING); else showFocus();
      },
      setTheme: (next) => {
        theme = { dark: !!next.dark, contrast: !!next.contrast };
        cy.style(style(palette(theme.dark, theme.contrast)));
      },
      destroy: () => cy.destroy(),
    };
  }

  window.pgMount = pgMount;
})();
