// PolyGraph · graful terapeutic, un singur renderer pentru aplicație și portal (QA2).
// Sursa e backend/polygraph/share/static/graph-core.js; app/PolyGraph/Graph/graph-core.js e o copie identică
// (aplicația merge offline), verificată byte cu byte de backend/tests/test_graph_core.py.
// Fără dependențe de WKWebView sau de pagină: primește containerul, graful (contracts/schema/graph.schema.json)
// și callback-urile; cine îl folosește decide ce înseamnă o atingere.
//
//   const graph = pgMount(container, graph, { dark, contrast, interactive, halo, onAlert, onMed, onReady });
//     halo: () => culoarea fundalului de sub graf (conturul numelor); implicit fundalul aplicației
//   graph.legend                     // substanțele numerotate din desen, ca pgLegend(graph)
//   graph.reset(animated)            // „Recentrează”: tot graful, centrat
//   graph.setTheme({ dark, contrast })
//   graph.destroy()
(function () {
  "use strict";

  // Layout radial determinist: pacientul în centru; medicamentele pe primul inel, ordonate astfel încât
  // perechile care interacționează să fie apropiate (mai puține linii care traversează desenul); fiecare
  // substanță pe aceeași rază cu medicamentul ei; alimentele și simptomele în afară, în direcția
  // substanțelor de care țin. Inelele sunt elipse, ca desenul să umple ecranul pe înălțime.
  // Clasele ATC nu se desenează (sunt în legendă), iar substanțele sunt cercuri numerotate, fără etichetă:
  // singurele texte din desen sunt numele medicamentelor și ale alimentelor, care nu se mai suprapun.
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
    const outer = cy.nodes('[type = "food"], [type = "symptom"]');
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
    separate(cy.nodes('[type = "food"], [type = "symptom"]').map((m) => m.id()), TAU / 14);

    const rx = W / 2, ry = Math.min(H / 2, rx * 1.45);
    const ring = { product: 0.56, substance: 0.8, atc_class: 0.8, food: 1.02, symptom: 1.02 };
    const positions = {};
    cy.nodes().forEach((node) => {
      const type = node.data("type");
      if (type === "patient") { positions[node.id()] = { x: 0, y: 0 }; return; }
      const r = ring[type] || 1.0, a = angle[node.id()] || 0;
      positions[node.id()] = { x: Math.cos(a) * rx * r, y: Math.sin(a) * ry * r };
    });
    pgPlaceLabels(cy, positions, angle);
    return positions;
  }

  // Unde stă fiecare nume, ca să nu se suprapună cu alte nume sau cu noduri: pentru fiecare medicament (apoi
  // aliment / simptom) se încearcă, în ordinea preferinței, dedesubt / deasupra / stânga / dreapta și se alege
  // locul cu cea mai mică suprapunere față de ce e deja așezat. Mărimea textului e estimată (fără DOM), cu
  // aceeași lățime maximă și aceeași împărțire pe rânduri ca stilul de mai jos.
  const NODE_SIZE = { patient: 34, product: 26, substance: 20, food: 14, symptom: 16 };
  const LABEL = {
    patient: { font: 13, max: 90 }, product: { font: 12, max: 84 }, food: { font: 10, max: 90 }, symptom: { font: 10, max: 90 },
  };
  const LABEL_GAP = 4;

  function labelSize(text, font, max) {
    // calibrat pe Cytoscape în Chrome / WKWebView: rânduri de font × 1.1, plus conturul (halo) și marginile
    const charW = font * 0.6, lineH = font * 1.1, pad = 7;
    const lines = [];
    String(text || "").split(/\s+/).filter(Boolean).forEach((word) => {
      const last = lines[lines.length - 1];
      if (last !== undefined && (last.length + 1 + word.length) * charW <= max) lines[lines.length - 1] = last + " " + word;
      else lines.push(word);
    });
    const w = Math.min(max, Math.max(0, ...lines.map((l) => l.length * charW)));
    return { w: w + pad, h: Math.max(lines.length, 1) * lineH + pad };
  }

  function labelBox(pos, half, size, side) {
    switch (side) {
      case "top": return { x1: pos.x - size.w / 2, x2: pos.x + size.w / 2, y2: pos.y - half - LABEL_GAP, y1: pos.y - half - LABEL_GAP - size.h };
      case "left": return { x2: pos.x - half - LABEL_GAP, x1: pos.x - half - LABEL_GAP - size.w, y1: pos.y - size.h / 2, y2: pos.y + size.h / 2 };
      case "right": return { x1: pos.x + half + LABEL_GAP, x2: pos.x + half + LABEL_GAP + size.w, y1: pos.y - size.h / 2, y2: pos.y + size.h / 2 };
      default: return { x1: pos.x - size.w / 2, x2: pos.x + size.w / 2, y1: pos.y + half + LABEL_GAP, y2: pos.y + half + LABEL_GAP + size.h };
    }
  }

  function overlapArea(a, b) {
    const w = Math.min(a.x2, b.x2) - Math.max(a.x1, b.x1), h = Math.min(a.y2, b.y2) - Math.max(a.y1, b.y1);
    return w > 0 && h > 0 ? w * h : 0;
  }

  function pgPlaceLabels(cy, positions, angle) {
    const obstacles = [];
    cy.nodes().forEach((node) => {
      const type = node.data("type"), half = (NODE_SIZE[type] || 0) / 2, p = positions[node.id()];
      if (!half || !p) return;
      obstacles.push({ x1: p.x - half - 2, x2: p.x + half + 2, y1: p.y - half - 2, y2: p.y + half + 2, weight: 1 });
    });
    const place = (node, text, sides) => {
      const type = node.data("type"), p = positions[node.id()], conf = LABEL[type];
      if (!p || !conf) return;
      const size = labelSize(text, conf.font, conf.max), half = (NODE_SIZE[type] || 0) / 2;
      let best = null;
      sides.forEach((side, rank) => {
        const box = labelBox(p, half, size, side);
        let cost = rank * 4;
        obstacles.forEach((o) => { cost += overlapArea(box, o) * o.weight; });
        if (!best || cost < best.cost) best = { side, box, cost };
      });
      // două nume unul peste altul sunt mai rele decât un nume peste un nod
      obstacles.push(Object.assign({ weight: 3 }, best.box));
      node.data("lside", best.side);
    };
    const TAU = Math.PI * 2;
    const norm = (a) => ((a % TAU) + TAU) % TAU;
    // pacientul: numele dedesubt, ca până acum
    cy.nodes('[type = "patient"]').forEach((node) => place(node, node.data("label"), ["bottom"]));
    // medicamentele, de sus în jos (ordinea e stabilă: după unghi); preferința: spre pacient pe verticală,
    // pentru că substanța fiecăruia stă spre exterior
    cy.nodes('[type = "product"]').sort((m, n) => positions[m.id()].y - positions[n.id()].y || (m.id() < n.id() ? -1 : 1))
      .forEach((node) => {
        const s = Math.sin(angle[node.id()] || 0), c = Math.cos(angle[node.id()] || 0);
        const vertical = s > 0.3 ? ["top", "bottom"] : ["bottom", "top"];
        const sides = c >= 0 ? ["left", "right"] : ["right", "left"];
        place(node, node.data("short") || node.data("label"), vertical.concat(sides));
      });
    // alimentele și simptomele: spre exterior, apoi celelalte
    cy.nodes('[type = "food"], [type = "symptom"]').forEach((node) => {
      const a = norm(angle[node.id()] || 0), c = Math.cos(a), s = Math.sin(a);
      const out = Math.abs(c) > 0.4 ? (c > 0 ? "right" : "left") : s < 0 ? "top" : "bottom";
      const rest = ["top", "bottom", "left", "right"].filter((x) => x !== out);
      place(node, node.data("label"), [out].concat(rest));
    });
  }

  // Culorile de sistem iOS, accentul și severitățile din Assets.xcassets (PGSeverity*), scrise ca hex / rgba: Cytoscape nu înțelege
  // variabilele CSS și nici sintaxa `rgb(0 0 0 / 0.1)` (QA-01).
  function palette(dark, contrast) {
    const p = dark
      ? {
          text: "#F2F2F7", muted: "#8E8E93", faint: "rgba(235,235,245,0.18)", node: "#2C2C2E", nodeBorder: "#48484A",
          accent: "#5CC2BC", red: "#E8806F", orange: "#E3A24F", gray: "#77726B", purple: "#BF5AF2", green: "#30D158",
          halo: "#121214",
        }
      : {
          text: "#1C1C1E", muted: "#8E8E93", faint: "rgba(60,60,67,0.18)", node: "#FFFFFF", nodeBorder: "#D1D1D6",
          accent: "#0E6B68", red: "#B23A2E", orange: "#9A5B0C", gray: "#8A857D", purple: "#AF52DE", green: "#34C759",
          halo: "#F7F5F2",
        };
    if (contrast) {
      p.muted = dark ? "#AEAEB2" : "#6C6C70";
      p.faint = dark ? "rgba(235,235,245,0.45)" : "rgba(60,60,67,0.45)";
      p.nodeBorder = dark ? "#8E8E93" : "#6C6C70";
      p.red = dark ? "#F2A396" : "#8E2A20";
      p.orange = dark ? "#F0C080" : "#7A4708";
      p.gray = dark ? "#A39E96" : "#5F5A53";
      p.halo = dark ? "#000000" : "#FFFFFF";
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

  // la deschidere, încadrarea pe alerta cea mai gravă nu se apropie mai mult de atât: rămân vizibile și vecinii
  const FOCUS_MAX_ZOOM = 1.4;

  // un contur în culoarea fundalului, ca liniile care trec pe sub un nume să nu-l facă greu de citit
  function halo(p) {
    return { "text-outline-color": p.halo, "text-outline-width": 2.5, "text-outline-opacity": 0.92 };
  }

  function style(p) {
    return [
      { selector: "node", style: {
          "label": "data(label)", "color": p.text, "font-family": "-apple-system, system-ui, \"Segoe UI\", Roboto, sans-serif",
          "font-size": 11, "text-valign": "bottom", "text-margin-y": 4,
          "text-wrap": "wrap", "text-max-width": 90,
          "background-color": p.node, "border-width": 1.5, "border-color": p.nodeBorder,
          "width": 18, "height": 18 } },
      { selector: 'node[type = "patient"]', style: Object.assign({
          "background-color": p.accent, "border-width": 0, "width": 34, "height": 34,
          "font-size": 13, "font-weight": 600 }, halo(p)) },
      { selector: 'node[type = "product"]', style: Object.assign({
          "label": "data(short)", "shape": "round-rectangle", "width": 26, "height": 26, "font-size": 12, "font-weight": 600,
          "text-max-width": 84, "line-height": 1.1, "border-color": p.accent, "border-width": 2 }, halo(p)) },
      { selector: 'node[type = "product"][severity = "critical"], node[type = "product"][severity = "major"]',
        style: { "border-color": p.red } },
      { selector: 'node[type = "product"][severity = "moderate"]', style: { "border-color": p.orange } },
      // substanța: un cerc cu numărul ei din legendă, în interior; bordura spune cât de gravă e cea mai grea legătură
      { selector: 'node[type = "substance"]', style: {
          "label": "data(num)", "width": 20, "height": 20, "font-size": 10, "font-weight": 700, "color": p.text,
          "text-valign": "center", "text-halign": "center", "text-margin-y": 0, "text-wrap": "none" } },
      { selector: 'node[type = "substance"][severity = "critical"], node[type = "substance"][severity = "major"]',
        style: { "border-color": p.red, "border-width": 2 } },
      { selector: 'node[type = "substance"][severity = "moderate"]', style: { "border-color": p.orange, "border-width": 2 } },
      { selector: 'node[type = "atc_class"]', style: { "display": "none" } },
      { selector: 'node[type = "food"]', style: Object.assign({
          "shape": "round-tag", "width": 14, "height": 14, "border-color": p.green, "font-size": 10 }, halo(p)) },
      { selector: 'node[type = "symptom"]', style: Object.assign({
          "shape": "star", "width": 16, "height": 16, "border-color": p.purple, "font-size": 10 }, halo(p)) },
      // locul numelui, ales de pgPlaceLabels
      { selector: 'node[lside = "top"]', style: { "text-valign": "top", "text-halign": "center", "text-margin-y": -LABEL_GAP } },
      { selector: 'node[lside = "bottom"]', style: { "text-valign": "bottom", "text-halign": "center", "text-margin-y": LABEL_GAP } },
      { selector: 'node[lside = "left"]', style: {
          "text-valign": "center", "text-halign": "left", "text-margin-x": -LABEL_GAP, "text-margin-y": 0, "text-justification": "right" } },
      { selector: 'node[lside = "right"]', style: {
          "text-valign": "center", "text-halign": "right", "text-margin-x": LABEL_GAP, "text-margin-y": 0, "text-justification": "left" } },

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

  // „Amlodipină Actavis 10 mg” → „Amlodipină Actavis”: în desen doar numele; concentrația e în legendă
  // și în detaliul medicamentului
  function shortName(label) {
    const full = String(label || "");
    const short = full.replace(/\s+\d+(?:[.,]\d+)?\s*(?:mg|mcg|µg|μg|g|ml|ui|%)(?:\s*\/\s*\S+)?(?:\s.*)?$/i, "").trim();
    return short || full;
  }

  // Legenda substanțelor din desen. Numerele urmează ordinea substanțelor în graph.nodes (backend-ul pune fiecare
  // substanță după medicamentul ei); aceeași regulă o folosește GraphLegend din aplicație.
  //   [{ num: 1, id: "s:B01AA07", label: "acenocumarol", severity, products: ["Sintrom 4 mg"], classes: ["…"] }]
  function pgLegend(graph) {
    const nodes = (graph && graph.nodes) || [], edges = (graph && graph.edges) || [];
    const byId = {};
    nodes.forEach((n) => { byId[n.data.id] = n.data; });
    const items = [], index = {};
    nodes.forEach((n) => {
      if (n.data.type !== "substance") return;
      index[n.data.id] = items.length;
      items.push({ num: items.length + 1, id: n.data.id, label: n.data.label, severity: n.data.severity || null,
        products: [], classes: [] });
    });
    edges.forEach((e) => {
      const d = e.data;
      if (d.type === "contains" && index[d.target] !== undefined && byId[d.source]) {
        items[index[d.target]].products.push(byId[d.source].label);
      }
      if (d.type === "in_class" && index[d.source] !== undefined && byId[d.target]) {
        items[index[d.source]].classes.push(byId[d.target].label);
      }
    });
    return items;
  }

  function pgMount(container, graph, options) {
    const opts = options || {};
    const legend = pgLegend(graph);
    const nums = {};
    legend.forEach((item) => { nums[item.id] = String(item.num); });
    // o copie, cu numărul substanței și numele scurt al medicamentului; graful primit rămâne neatins
    const elements = {
      nodes: ((graph && graph.nodes) || []).map((n) => {
        const extra = n.data.type === "substance" ? { num: nums[n.data.id] }
          : n.data.type === "product" ? { short: shortName(n.data.label) } : {};
        return { data: Object.assign({}, n.data, extra) };
      }),
      edges: ((graph && graph.edges) || []).map((e) => ({ data: Object.assign({}, e.data) })),
    };
    let theme = { dark: !!opts.dark, contrast: !!opts.contrast };
    function themedStyle() {
      const p = palette(theme.dark, theme.contrast);
      const halo = typeof opts.halo === "function" ? opts.halo() : null;
      if (halo) p.halo = halo;
      return style(p);
    }
    const interactive = opts.interactive !== false;
    const cy = cytoscape({
      container: container || undefined,
      styleEnabled: true,
      elements: elements,
      style: themedStyle(),
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
      if (cy.zoom() > FOCUS_MAX_ZOOM) {
        cy.zoom(FOCUS_MAX_ZOOM);
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
      legend: legend,
      reset: (animated) => showAll(!!animated),
      resize: () => {
        cy.resize();
        if (showingAll) cy.fit(undefined, PADDING); else showFocus();
      },
      setTheme: (next) => {
        theme = { dark: !!next.dark, contrast: !!next.contrast };
        cy.style(themedStyle());
      },
      destroy: () => cy.destroy(),
    };
  }

  window.pgMount = pgMount;
  window.pgLegend = pgLegend;
})();
