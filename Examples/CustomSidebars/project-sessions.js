// Project/tab explorer using cmux's native custom-sidebar API.
// No processes, transcript scraping, or guessed agent state. Project artwork
// stays in the primary sidebar until cmux exposes it to custom sidebars.
const [expanded, setExpanded] = signal({});

function openWorkspace(w) {
  cmux("workspace.select", { workspace_id: w.id });
}

function openTab(w, t) {
  openWorkspace(w);
  if (t.surfaceId) cmux("surface.focus", { workspace_id: w.id, surface_id: t.surfaceId });
}

function agentFor(w, t) {
  return (w.agents ?? []).find((a) => a.surfaceId === t.surfaceId || a.panelId === t.id);
}

function statusLabel(w, t) {
  const state = agentFor(w, t)?.status;
  if (state === "working") return "Working";
  if (state === "needs_input") return "Needs you";
  if (state === "idle") return "Idle";
  if (state === "ended") return "Ended";
  return t.hasUnread ? "Unread" : "";
}

function stateColor(w, t) {
  const state = agentFor(w, t)?.status;
  return state === "working" ? "#8eaec8" : state === "needs_input" ? "#c49ba7" : "tertiary";
}

function isExpanded(w) {
  const values = expanded();
  return values[w.id] === undefined ? w.selected : values[w.id];
}

sidebar(() => VStack({ spacing: 6 }, [
  HStack({ spacing: 6 }, [
    Text("Projects & tabs").font(13).weight("semibold"),
    Spacer(),
    Text(() => String((data.workspaces() ?? []).reduce((n, w) => n + (w.tabs ?? []).length, 0)))
      .font(11).color("tertiary"),
  ]).paddingHorizontal(10).paddingVertical(6),
  ForEach({ items: data.workspaces, key: (w) => w.id }, (w) =>
    VStack({ spacing: 2 }, [
      HStack({ spacing: 7 }, [
        Text(() => isExpanded(w()) ? "⌄" : "›").font(14).color("secondary")
          .onTap(() => setExpanded({ ...expanded(), [w().id]: !isExpanded(w()) })),
        Text(() => w().title).font(12).weight("semibold").lineLimit(1).truncation("tail")
          .onTap(() => { openWorkspace(w()); setExpanded({ ...expanded(), [w().id]: true }); }),
        Spacer(),
        Text(() => String((w().tabs ?? []).length)).font(10).color("tertiary"),
      ]).paddingHorizontal(10).paddingVertical(7)
        .background(() => w().selected ? "#8eaec825" : null).cornerRadius(7),
      VStack({ spacing: 2 }, [
          ForEach({ items: () => isExpanded(w()) ? (w().tabs ?? []) : [], key: (t) => t.id }, (t) =>
            HStack({ spacing: 6 }, [
              Image("rectangle").font(10).color("tertiary"),
              Text(() => t().title || "Terminal").font(11).lineLimit(1).truncation("tail"),
              Spacer(),
              Text(() => statusLabel(w(), t())).font(10).weight("semibold")
                .color(() => stateColor(w(), t())),
            ]).paddingLeading(24).paddingTrailing(10).paddingVertical(6)
              .background(() => t().focused && w().selected ? "#8eaec825" : null)
              .cornerRadius(6).hoverBackground("#7f7f7f20")
              .onTap(() => openTab(w(), t())),
          ),
      ]),
    ]),
  ),
  Spacer(),
]));
