# visits: the web as one event stream

A design, accepted; phase 1 is built (section 5). It makes Adrian's web properties (untitled.garden and its project subdomains, ui.adriangalilea.com, adriangalilea.com) observable from the visitor's browser through to the server, on the event stream this repo specifies. It lives here because its core is a change to that contract (shipping events, and a convention for web pages); the rest of the work lands in ts-utils, ui, garden and one new collector, each named below.

Order of the doc: what we need to know, the views that answer it, how producers and readers work, prior art, phases, decisions. Everything is derived from the questions; a question nobody would act on was cut.

## 0. What exists today

| source | what it holds | where | limits |
|---|---|---|---|
| garden path sensor | one row per page shown (`page_view`: at, day, visitor, host, path, outside referrer, read depth, time on screen), 180 days | `apps/garden/components/visit-sensor.tsx` beacons to `app/api/visit/route.ts`, written by `lib/visits.ts` into the garden Turso db | visitor = sha256(daily random salt, IP, user agent), salt deleted the next day: journeys within a UTC day, nobody across days. Superadmin sessions and crawler user agents are dropped. No timings, no errors, no events, no link to the server |
| `buildJourneys` | visits (30 min gap), places, routes, hops, sources, per page exits and median depth | `untitled/packages/metrics/journeys.ts`, pure | the "whole visits, place by place" view renders `routes`: each visit's places with only consecutive repeats merged, top 12 by count. A visit that ping-pongs between projects keeps every stop, so one 80-step visit prints as an 80-stop wrapped line and swamps the column |
| garden KPI registry | distribution counters (download clicks, downloads, update checks, feed polls, buy clicks, paid downloads, install check-ins) | `lib/kpi-store.ts`, ts-utils `metrics` over `METRICS_SCHEMA` in garden's Turso | daily aggregates, no ordering, no visit |
| Cloudflare Web Analytics | page loads, hosts, referrers, countries, Core Web Vitals | beacon in garden's root layout, read by `packages/metrics/rum.ts` | sampled (about 10% at this volume, every count a multiple of 10), no visitor, no path |
| ui metrics | install/update command copies, registry JSON requests, in the shared Turso `metrics` db, project `ui` | `ui/lib/metrics.ts`, `pnpm kpi` | aggregates only, by design: no IPs, user agents or identities |
| Vercel Analytics | page views, referrers | ui and adriangalilea.com (plus Speed Insights there) | provider's store and retention, no export of paths |
| server logs | garden writes no structured events at all; Vercel Hobby keeps runtime logs for 1 hour | | what the server did behind a visit is gone within the hour |
| xtldr | the reference producer: an `update` span per Telegram update with child spans, relay jobs joined through `traceparent` | Workers Logs (7 days), the garden's hand-rolled live-logs pane | not a website; shows the contract works across processes |

Readers already built: `logs` (go-utils) renders any stream, and ui has `log` (live tail), `trace` (waterfall, running spans, detached spans, zoom on the timeline view model) and `telemetry` (reads the stream into both, linked).

## 1. What we need to know

Each question names the smallest data that answers it. "Visit" means one person's pages within 30 minutes of each other on one site, across its subdomains, recognised for one UTC day at most.

### Adrian looking (product)

| # | question | minimal data |
|---|---|---|
| P1 | Where do visits land, and from where? | per visit: first page, outside referrer host (and `utm_source` when present) |
| P2 | Where do they go next from a page or a project? | per visit: pages in order |
| P3 | Where do they leave? | per visit: last page; per page: views and exits |
| P4 | Which paths are common? | the ordered pages per visit, collapsed (rules in section 2) |
| P5 | What do they do on a page? | per page shown: which named sections were reached (`hero`, `features`, `kanban`, `changelog`), time on screen, and the named events fired there (main action, demo played, command copied) |
| P6 | Did a change improve a flow? | every page shown carries the deploy that served it (`build`, the git sha), so any measure splits at a deploy instead of at a guessed date |
| P7 | Which project pages convert to the main action? | per project: visits that saw its page, visits that fired its `main action`, and (already counted server-side) downloads |

Section reach replaces percent scrolled. Depth as a share of the page stops being comparable the moment a page grows: 60% of a page with a new feature card is not 60% of the old one. "Reached the changelog" is felt in the unit that matters and survives redesigns.

### Adrian developing

| # | question | minimal data |
|---|---|---|
| D1 | What was slow in this visit? | per page: TTFB, LCP, INP, CLS; per same-origin request: a client span (method, path, kind, status, duration) |
| D2 | What failed? | uncaught errors and unhandled rejections as `error` lines on the page; failed requests (status >= 400, network errors) as failed spans; error boundaries as `fail` lines |
| D3 | What did the server do behind each step? | the request carries `traceparent`; the server's spans are children of the client's request span, with their own children (Turso, R2, Stripe) |
| D4 | Which pages are slow or failing across visits, and since which deploy? | the same fields, aggregated per page and per `build` |
| D5 | Is collection itself working? | the collector's own events (accepted, rejected and why), and a write probe, as ui's `pnpm kpi` already does |

### Agents

A coding agent needs to decide where to iterate and then verify a change, from a shell, in JSON, without a browser. Every command below has a human rendering at a terminal and `--json` for agents (the `garden kpi` and `pnpm kpi` rule). The CLI is `visits`, in the collector's repo (section 6).

```sh
visits paths --site untitled.garden --days 14 [--by place|page] [--json]
visits around lore --days 14 [--json]             # came from / went to, one node
visits entry --days 14 · visits exit --days 14
visits funnel "studio > lore > lore:main action" --days 30 [--json]
visits compare --build 8541cd7 [--metric <funnel or measure>] [--json]
visits pages --slow --days 7 [--json]             # p75 LCP / INP / TTFB per page, per build
visits errors --days 1 [--json]                   # grouped by message, page, build
visits list --days 1 [--longest|--failed|--probe] # visits, newest first
visits trace <visit-id> | logs                    # the visit's events as NDJSON
visits tail --site untitled.garden | logs         # live, pushed, never polled
```

What the JSON says, so an agent can act without guessing:

```json
{"site":"untitled.garden","window":{"from":"2026-09-29","to":"2026-10-12"},"visits":412,
 "funnel":[{"step":"studio","visits":412},{"step":"lore","visits":131,"lost_to":[{"to":"chill","visits":40},{"to":"(left)","visits":201}]},
           {"step":"lore:main action","visits":27,"lost_to":[{"to":"(left)","visits":71}]}]}
```

```json
{"build":"8541cd7","before":{"from":"2026-10-01","to":"2026-10-08","visits":210,"hits":31},
 "after":{"from":"2026-10-08","to":"2026-10-12","visits":96,"hits":19},
 "rate":{"before":0.148,"after":0.198,"after_interval":[0.13,0.29]},"verdict":"noise"}
```

`verdict` is `better`, `worse` or `noise`, from a 95% interval on each rate, never from the point estimates. At a few hundred visits most changes are inside the noise, and the answer an agent must be able to give is "not yet, needs about N more visits", not a percentage that reads like a win.

Verifying a change: an agent drives its own headless browser against production or a preview, which the collector records as a **probe** (the page sees `navigator.webdriver`), kept out of every product number and readable with `visits list --probe` and `visits trace`. The agent then reads its own visit back: page spans, request spans, server spans, errors. That closes the loop `scripts/record-load.mjs` opened for paint, for behaviour.

### Killed

Asked often by analytics tools, cut here because nothing would change after reading them, or because the data would cost privacy: returning visitors and retention cohorts (impossible by design, and kept so); session replay, click maps and scroll heatmaps; per-browser and per-OS breakdowns (they need the user agent; viewport class is kept instead); average session duration and bounce rate as headlines (a one-page visit that read to the changelog is not a failure; section reach says what bounce rate pretends to); time-of-day heatmaps; country beyond the top few (Cloudflare RUM already has it).

## 2. UX

Everything below is a view over the same rows, in garden's admin "discovery" section (apex desk: the whole studio; a project console: visits that touched that project). One window control for all of it: `live · today · 7d · 30d`, the one the bot live-logs pane already uses.

### Paths, collapsed

The rule that fixes the 80-step visit: **a path is keyed by its first four distinct places, in the order first seen**; a return to a place already on the path is not a new stop; whatever comes after the fourth distinct place is a count. The visit's length is a separate number beside it, so a long visit is visible without swamping the list.

```
paths · 412 visits · 14 days                          visits  pages/visit
studio → lore                                            88      2
studio                                                   71      1
lore                                                     52      1.4
studio → lore → chill                                    14      4
lore → chill → xtldr → trash  +3                          1     80   (open)
```

Beside it, the same paths as a prefix tree, which answers "after landing on X, what next" by folding:

```
studio 183 ─┬─ lore 88 ─┬─ (left) 61
            │           ├─ chill 14 ─── (left) 9
            │           └─ xtldr 7
            ├─ (left) 71
            └─ trash 12 ── (left) 10
lore 52 ────┬─ (left) 37
            └─ studio 9
```

`--by page` gives the same at page level (ids folded: `lore requests/:n`). Long single visits are not hidden by any of this: `list --longest` and a "deepest visits" list under the paths open each one as a trace, where an 80-page visit belongs (it is a story about one person, not a path).

### Around one node (next-page flow)

A two-sided bar list around a chosen place, page or event, simpler than a Sankey and enough for "where do they go next":

```
          came from                 lore                went to
   studio ████████████ 88                        (left) ███████████ 98
   (direct) █████ 30                             chill  ███ 21
   reddit ███ 13          131 visits             studio ██ 9
                          27 fired main action   xtldr  █ 7
```

Clicking a node on either side re-centres on it. A three-step Sankey (entry, second, third) is a later variant of the same data if the two-sided view proves too narrow.

### Entry and exit

One table per page: entered, views, exits, exit share, median time on screen, and section reach as a small strip of the page's sections (filled where the median view got to). Exits read beside reach: a page that loses people before its main section is a different problem from one that loses them after reading everything.

### Drop-off along a defined path

Steps are places, pages or named events. Each step shows how many visits reached it and, for those that did not reach the next, where they went instead (top three, plus "left"):

```
studio            412  ██████████████████████████
lore              131  ████████          281 lost: left 201 · trash 40 · chill 22
lore:main action   27  ██                104 lost: left 71 · chill 21 · studio 9
download (server)  19  █
```

Funnels are typed in the view (and the CLI) as a string, `studio > lore > lore:main action`; a project's default funnel (studio, its page, its main action) needs no definition because every project has exactly one main action.

### One visit as a trace

The visit list (newest first, with entry, places, page count, duration, a mark when anything failed, the build) opens one visit in ui's `trace` beside ui's `log`, linked both ways:

```
visit 3f2a… · 6 pages · 4m12s · build 8541cd7
├ page studio /                    ▕█▏                         1.9s  lcp 820ms
│  └ fetch rsc /lore                ▕▏                          140ms
├ page lore /                        ▕██████████████▏           2m03s  reached features, kanban
│  ├ fetch action vote                  ▕█▏                     310ms
│  │  └ POST vote (garden)               ▕█▏                    270ms
│  │     └ turso insert vote              ▏                      38ms
│  └ main action                          · line
├ page chill /                     ...
```

Page spans are seconds to minutes and requests are milliseconds, with long idle stretches between pages. The trace's axis therefore needs one new ability: **idle time folded** (a stretch where no span is open is drawn as a short break on the axis, with its length written in it), which is a time map in ui's own time vocabulary, not a new model. Live, a running visit's page span is drawn running (the contract's own truth for a span with no end) and new spans arrive as they are written.

### Live and history

- **Live** is pushed: the collector holds a WebSocket per viewer and sends each accepted event once. The visit list fills and running visits grow in place; the log tails; `visits tail` is the same feed in a terminal. Nothing polls.
- **History** is a query, run when the window changes. Aggregate views (paths, around, funnel, entry and exit) are history views; "today" recomputes on each visit that closes while the view is open, carried by the same push, so they stay current without a timer.

### What is a registry item and what stays in garden

| piece | where | why |
|---|---|---|
| `paths` | ui, public | sequences with counts in, the collapsed list and the prefix tree out; knows nothing of visits |
| `flow` | ui, public | the two-sided view around a node (nodes and weighted edges in), Sankey as a later mode |
| funnel bars | ui `charts` (planned in ui's TODO.md) | a bar list with losses between steps is a chart, and shares hover and colour with the rest of `charts` |
| `trace` | ui, exists | gains folded idle time, following new spans while live, and drawing several traces under one composed root |
| `log`, `telemetry` | ui, exist | `telemetry` gains the composition of several trees under one root (the visit) |
| `page-sensor` | ui, public | the React face of the browser producer (section 3) |
| the discovery section | garden | which views, in which order, per desk or console; place names, project actions, default funnels |

## 3. DX

### The contract: a browser visit in the event stream

**A page shown is a span, and the root of its own trace.** A visit is not in the stream at all: it is a fact the collector holds, because the collector is the only party that sees the caller (the IP that makes the daily hash). Putting the visit into the stream would need the browser to learn its visit id before writing anything, a round trip before every page's first event, and either a cookie (refused) or rewriting ids after the fact (which breaks the backend spans that already carry them). So the stream stays honest per process, and the reader composes a visit from its pages.

| browser moment | in the stream |
|---|---|
| a page shown (first paint of a load, or activation of a prerendered page) | `page` span opens: a new `trace_id`, minted in the browser |
| a soft navigation (client-side route change) | the current `page` span ends, a new one opens with `nav: "soft"` and `from` (the previous path) |
| the tab hidden | the `page` span ends. Hidden is the last moment a browser reliably lets a page send anything; a span left open until `pagehide` is a span mobile browsers never end |
| the tab shown again | a new `page` span, `nav: "resumed"`, same path |
| restored from the back/forward cache | a new `page` span, `nav: "bfcache"` |
| prerendered but never shown | nothing |
| a same-origin request | a `fetch` child span; its `traceparent()` goes on the request's `traceparent` header |
| the server handling it | `log.join(header)`: the server's spans are children of the `fetch` span, in the same trace |
| a named event | a line written through the page span: `page.info("main action", { label })` |
| an uncaught error, an unhandled rejection | an `error` line on the page span with `err` |
| work the visitor waits for (a vote, an upload) | an explicit child span: `page.span("vote", …)` |

The `page` span's fields, at its start: `host`, `path` (query dropped, except an allowlist: `utm_source`, `ref`), `nav` (`navigate`, `reload`, `back_forward`, `prerender`, `soft`, `resumed`, `bfcache`), `from` on a soft navigation, `referrer` (the outside host only, never a URL), `build`, `viewport` (`phone`, `tablet`, `desktop`, from the width), and what the app knows that the collector cannot: `place` (garden: the project slug or `studio`) and `route` (the route pattern, `requests/:n`). On its end, through `set`: `seen_ms` (time visible), `reached` (sections in the order first reached), `ttfb_ms`, `lcp_ms`, `inp_ms`, `cls`. A `fetch` span's fields: `method`, `path`, `kind` (`rsc`, `action`, `api`, `other`, from the request's own headers), `status`.

`place` and `route` come from the page because the page holds the fact: the garden knows that `untitled.garden/lore` is the lore project; a collector would have to be taught garden's routing and would drift from it.

**Visit identity without cookies or personal data.** The collector reads the caller's IP and user agent, hashes them with a random salt of the day, and stores neither. The salt lives in the site's Durable Object storage and is deleted by an alarm at the end of the UTC day (today it is deleted only by the next day's first view, so a quiet night keeps it alive longer than it should). Never derived from a lasting secret, for the reason `lib/visits.ts` states. Same privacy line as today: journeys within a day, nobody across days, and once the salt is gone nobody can trace a hash, Adrian included. Nothing is stored in the browser, so no consent banner. The garden's `garden-arrived` cookie (30 minutes, parent domain) must not start carrying an id: that is what would turn it into a tracking cookie.

**Visit assignment** happens when a `page` span's start arrives: the site's Durable Object (one per registrable domain, so `ui.adriangalilea.com` and `adriangalilea.com` share visits, and every `*.untitled.garden` too) maps the hashed caller to its open visit (last page within 30 minutes) or opens one, and records `trace_id → visit`. Every later event of that trace, a server span included, belongs to the visit by its `trace_id`, with no further lookup of the caller.

**Who is not a visitor.** Crawlers (user agent, read and dropped) are not recorded. Probes (`navigator.webdriver`: an agent's or a script's browser) and staff (a display cookie `garden-staff=1` set on a superadmin sign-in, saying "staff" and not who) are recorded and flagged, kept out of every product number, kept 7 days, and shown in the visit list, because Adrian looking at his own visit as a trace is the developer view.

**What is personal data and is refused.** The collector refuses any web event whose fields hold a key from a short denylist (`ip`, `user_agent`, `email`, `user`, `name`, `phone`) and writes one `warn` in its own stream naming the service and key. Garden's server spans carry no account ids; a span that needs to say "a signed-in user" says `signed_in: true`.

### Producers

**Browser, one line.** In the root layout:

```tsx
<PageSensor service="garden-web" collector="https://events.untitled.garden" place={place} />
```

`PageSensor` (ui `page-sensor`) opens and ends `page` spans on the moments in the table above, using `usePathname` for soft navigations and the existing `whenShown` rule for prerendered pages. Underneath it is framework-free code in ts-utils (`@adriangalilea/utils/log/web`): the lifecycle, web vitals (from the `web-vitals` library, which already ends its measures on hidden), error capture, the same-origin `fetch` wrapper, and shipping.

The fetch wrapper is the one implicit piece, and it is the browser's form of a rule the contract already has: a process started with `TRACEPARENT` joins it with no code. It touches only same-origin requests (a custom header on a cross-origin request would add a CORS preflight), never overwrites a `traceparent` the caller set, and parents to the page span that is current, which is a fact the sensor holds, not an ambient context.

**Named events are explicit calls.** `usePage()` returns the current page span:

```tsx
const page = usePage()
page.info("main action", { label: project.action.label })
```

Messages are constant and facts go in fields (xtldr's rule). Sections are marked in the markup the page already has (`data-section="changelog"` on the scrollspy's anchors) and recorded once per page span when first on screen; they cost no event, only the `reached` field on the span's end.

**Server, zero to one line.** Every library honours `LOG_SHIP` (below), so garden's server ships by setting two environment variables on Vercel. A route handler joins the browser's trace with the line the contract already gives it:

```ts
export const POST = traced("POST /api/feedback/vote", async (s, request) => { … })
```

`traced` (ts-utils `@adriangalilea/utils/log/next`) is `log.join(request.headers.get("traceparent")).span(name, …)` plus `after(flush)`, so a frozen serverless instance never holds unsent events. Server actions get the same as `tracedAction`, reading the header through `headers()`.

### Shipping (the contract change)

Today an event goes to stderr only. Shipping adds one destination with the same bytes:

| variable | setter | value |
|---|---|---|
| `LOG_SHIP` | `setLogShip` | a URL. Every event that passes its threshold is also POSTed there |
| `LOG_SHIP_TOKEN` | `setLogShipToken` | a bearer sent with each batch (servers); browsers send none |

The wire: a batch is the exact JSON lines the stream writes, joined by `\n`, as the body of a POST with `Content-Type: text/plain;charset=utf-8` (the one type `navigator.sendBeacon` and a cross-origin `fetch` send without a preflight). At most 64 KB per batch (the beacon's limit). A writer sends a batch when 2 seconds have passed since its first event, at 50 events, at a span's end that has no parent (so a request's whole trace leaves together), and immediately on `visibilitychange: hidden` and `pagehide` in a browser. The answer is `204`, or `400` with `{"accepted":n,"rejected":[{"line":i,"why":"…"}]}`. Delivery is at most once from a browser and at least once from a server that retries; the collector drops a span event it has already stored (same `span_id` and `phase`). A writer never blocks on shipping and never throws from it: a failed batch is one `warnOnce` on stderr.

Shipping changes no event and no key. The schema stays as it is.

### Readers

- **The collector's read API** is the only reader of the store. It shapes everything (paths, around, funnel, compare, pages, errors, a visit's events) and answers JSON, or NDJSON for event lists. Garden's admin, the `visits` CLI and agents all read it, so `buildJourneys` and its siblings move there once and are deleted from `@workspace/metrics`.
- **`visits`** is a thin CLI over that API: human tables at a terminal, `--json` for agents, NDJSON for `trace` and `tail` so `logs` renders them (`visits trace <id> | logs --level warn`).
- **`logs`** is unchanged. It already reads any stream on stdin.
- **ui** renders: `log`, `trace` and `telemetry` from NDJSON, `paths` and `flow` from the JSON shapes.

### The collector

A Cloudflare Worker with a Durable Object per site and one D1 database, answering on a first-party subdomain of each site (`events.untitled.garden`, `events.adriangalilea.com`, as Workers custom domains: the sites' own records stay DNS-only for Vercel).

```
browser  ─ sendBeacon / fetch keepalive ─▶  Worker  ─▶  site DO ─┬─▶ D1 (events, pages, visits)
server   ─ POST + bearer ────────────────▶   │  validate   │      └─▶ WebSocket viewers (live)
                                             │  parseEvent │  visit assignment, daily salt
garden admin · visits CLI ◀── read API ──────┘
```

- **Ingest**: each line is parsed with ts-utils' `parseEvent` (the contract's own reader) and checked against the schema; browser batches must come from an allowed `Origin` with an allowed `service`; denylisted keys refuse the line.
- **Storage, D1.** Three tables: `event` (every accepted line, with `day`, `service`, `trace_id`, `span_id`, `phase`, `level`, `visit` and the line itself), `page` (one row per ended `page` span, derived at ingest: visit, order, place, route, nav, build, seen, reached, vitals, error and request counts) and `visit` (one row per visit, written when its Durable Object closes it 30 minutes after its last page: entry, exit, places, pages, duration, source, flags). Reasons:
  - D1 is a binding from the Worker: no credential in code, and it is included in Workers Paid, already paid ($5/month; 50M rows written, 25B rows read and 5 GB stored per month included).
  - Turso is where garden's data lives and must stay (garden's compute is on Vercel, in Turso's region). But the collector's compute is a Worker, which is the case the studio's own infra note names as the one that flips the choice to D1: from a Worker, Turso is a cross-provider HTTP call with a token.
  - Workers Logs keeps 7 days and offers no shaping of visits; it stays what it is, the collector's own log.
  - Garden's Turso `metrics` database stays the home of aggregates (`METRICS_SCHEMA`). Visits and events are not counters.
- **Retention**: `event` 30 days (traces, debugging, and re-deriving `page` rows after a fix); `page` and `visit` 180 days, as `page_view` today; probe and staff rows 7 days. A Durable Object alarm deletes by day.
- **Sampling**: none. Estimated volume at 500 visits a day, 4 pages each and about 12 events a page, is about 0.75M rows written a month with the derived rows and indexes, under 2% of D1's included writes, with Worker and Durable Object requests far inside theirs. Marginal cost: zero. If volume ever matters, sample whole visits at the moment the Durable Object opens them, never single events (a visit's trace is never partial), and keep every visit with an error.
- **Live**: viewers hold hibernatable WebSockets on the site's Durable Object, so an idle viewer costs nothing and an event reaches every viewer once, as it is accepted.
- **Its own stream**: the collector writes the contract's events too (`service: "events"`), to Workers Logs: accepted and rejected counts per batch, refusals with their reason, visits opened and closed. A write probe, as ui's `/api/metrics/health`, answers `visits health`.

### Exactly what changes where

**utils (this repo)**
- README: a "Shipping" section (`LOG_SHIP`, `LOG_SHIP_TOKEN`, the batch, when a writer sends, the answer, delivery, never blocking) and the two variables in Configuration.
- README: a "Web pages" section, the convention above (a page is a span and a trace root; `nav`, the lifecycle moments, the `page` and `fetch` span fields; the visit is the collector's). It belongs here because it is the agreement between a producer (ts-utils) and readers (the collector, ui), which is what this repo is for.
- `schema/page.schema.json`: the fields of a `page` span's start and end and of a `fetch` span, which the collector validates against and ts-utils' runnable example checks itself against. `event.schema.json` is unchanged.
- Conformance: a `ship` run. `run.sh` starts a local listener, runs each probe with `LOG_SHIP` pointing at it, and diffs what arrived against `expected.jsonl`: the shipped bytes must be the stderr bytes, for all three languages. The web lifecycle itself runs only in a browser and is proved by ts-utils' runnable example, not here.

**ts-utils**
- `log`: the `LOG_SHIP` sink in Node, Bun, Workers and browsers (batching, the flush triggers, `flush()`), behind the existing threshold. Today `emit` writes only to the console.
- `log/web`: the page lifecycle, vitals, errors, the same-origin fetch wrapper, probe detection.
- `log/next`: `traced` and `tracedAction`.

**go-utils, py-utils**
- The `LOG_SHIP` sink, for the conformance run and for Adrian's own daemons, which then ship with no code. `logs` is unchanged.

**ui**
- New public items: `page-sensor`, `paths`, `flow`. Funnel bars inside the planned `charts`.
- `trace`: folded idle time, following arriving spans while live, several traces under one composed root.
- `telemetry`: composing several span trees under one named root.
- ui.adriangalilea.com mounts `page-sensor` (service `ui-web`); whether Vercel Analytics then goes is an open question.

**garden** (read-only for this design; another session is editing its admin now, so phase 0 must be sequenced with it)
- Mounts `PageSensor`, passes `place`, marks sections, fires `main action` from `HeroAct`, sets the `garden-staff` display cookie on a superadmin sign-in.
- Server: `@adriangalilea/utils` to the version with `log`, `LOG_SHIP` set on Vercel, `traced` on route handlers and server actions.
- Discovery section rebuilt from `paths`, `flow`, funnel bars, the visit list and `trace`, reading the collector's API.
- Deleted once the collector has the history: `components/visit-sensor.tsx`, `app/api/visit`, `lib/visits.ts`, the `page_view` and `visit_salt` tables, `buildJourneys` and the `Journeys` DTO. No dual path stays.
- The hand-rolled bot live-logs pane moves onto ui's `log` and `telemetry` (separate work, same stream).

**the collector** (new): the Worker, the Durable Object, D1 migrations, the read API, `visits`.

## 4. Prior art

- **OpenTelemetry for the web** (`sdk-trace-web`, document-load and fetch instrumentation). Take: the page load as a span, request spans that propagate W3C `traceparent` to allowed origins only, batches flushed on `visibilitychange`. Refuse: OTLP as the wire (our stream is the wire, and readers already exist), the SDK's weight in a page, the zone-based ambient context, auto-instrumented clicks (noise), resource attributes carrying the user agent.
- **Session RUM** (Sentry, Datadog RUM, Elastic). Take: the view as the unit, ended on hidden; vitals per view; linking a frontend request to its backend trace through a header. Refuse: session cookies, replay, per-session sampling by default.
- **Plausible.** Take: the cookieless daily-salt hash (the garden's model already), funnels as steps of pages or events, goals with properties. Refuse: nothing to trace a step with, no link to the server.
- **PostHog paths and funnels.** Take: the path tree with a start or end point and a step limit, path cleaning (fold ids), "where did those who dropped off go". Refuse: person profiles, identity stitching, autocapture of every click, replay.
- **GA4 path exploration.** Take: the reverse tree (what led to a node), which `around` covers.
- **Vercel Web Analytics.** Take: the same daily-hash identity, confirming the line holds commercially. Refuse: no paths, no export, retention by plan.
- **Cloudflare Web Analytics.** Keep it running as an independent, sampled check of volume and vitals; it cannot be the source of journeys (no visitor, sampled).

## 5. Phases

Smallest useful first. Each ends with something Adrian looks at.

0. **Read what is already there, better.** Garden only, on the existing `page_view` rows: paths keyed by first four distinct places with a page count and "+n", the prefix tree, the around-a-place view, entry and exit, a "deepest visits" list. No new collection. *Adrian sees the discovery section read at a glance, the 80-step visit as one row with "80 pages".* Sequenced with the session editing garden's admin now.
1. **Shipping and the collector.** `LOG_SHIP` in the three libraries with the conformance `ship` run; the collector's Worker, Durable Object, D1 `event` table, live WebSocket and `visits tail`; garden's server adopts `log` and `traced`. *Adrian sees `visits tail | logs` move live in a terminal while he clicks the site, and garden's server spans kept for 30 days instead of 1 hour.*
   - **Built**: the Shipping section of the README and the conformance `ship` run; ts-utils' sink (Node, Bun, Workers through `flushLog`, browsers through `sendBeacon`), committed, not released; the collector in `adriangalilea/visits`, live at `events.untitled.garden` and `events.adriangalilea.com` (ingest with per-site tokens, D1 `event` with 30-day retention, `GET /events`, `/tail`, `/health`, `visits tail | logs`, proved end to end from a local process); `logs` renders a live pipe line by line (go-utils, it buffered stdin until EOF).
   - **Left**: the sink in go-utils and py-utils (their `ship` run reports pending); `log/next` (`traced`, `tracedAction`) and garden's server adopting them, sequenced with the session rebuilding garden's admin; a ts-utils release so the published probe passes `ship`.
2. **Pages in the browser.** `log/web` and `page-sensor`; garden mounts it; `page` and `visit` rows; the visit list and one visit as a trace (with folded idle time) in garden's admin. Garden's old sensor keeps running for two weeks so the two counts can be compared once, then it is deleted. *Adrian opens his own visit (flagged staff) and sees each page, each request, and what the server did inside it.*
3. **Product views on the collector.** Paths, around, funnels, entry and exit, `compare --build` with its verdict, `pages --slow`, `errors`, in the read API and the CLI; ui's `paths` and `flow` items and funnel bars; garden's discovery reads the collector; sections and `main action` wired; `buildJourneys` deleted. *Adrian sees each project's funnel to its main action, and whether the last deploy moved it or is still noise.*
4. **Spread.** ui.adriangalilea.com and adriangalilea.com mount `page-sensor`; optionally xtldr's Workers feed the same store through a Tail Worker (no code in the bot), giving its events more than Workers Logs' 7 days and one `visits`/`logs` surface for everything. *Adrian sees the registry's own visitors as paths (which component pages lead to an install copy) beside the studio's.*

## 6. Decisions

Adrian's, on the questions this section held:

1. **The collector is its own private repo, `adriangalilea/visits` (`~/Developer/visits`)**: the Worker, its Durable Object, D1, the read API and the `visits` CLI. It serves every site (garden, ui, adriangalilea.com), so it lives outside any one of them.
2. **Retention**: raw events 30 days; pages and visits 180 days.
3. **Adrian's own visits and agents' visits are recorded and flagged, never dropped** (staff and probe), kept out of every product number. Their 7 days stand as proposed.
4. **Country and screen-size class are kept, coarse**: two letters from Cloudflare's edge, never stored with the IP; `phone`, `tablet` or `desktop` from the width, never the user agent.
5. **No scroll depth; "sections reached" instead.**

Where the questions were left open, decided by the doc's own reasoning:

6. **A page ends at hidden**, and a return is a new span with `nav: "resumed"`: a span mobile browsers never end is a lie, two spans are the truth.
7. **Funnels are typed ad hoc, plus one default per project** (studio, its page, its main action), since every project has exactly one main action; saved definitions wait until a funnel is typed twice.
8. **Vercel Analytics and Speed Insights go** once ui.adriangalilea.com and adriangalilea.com have run beside the collector for two weeks and the counts were compared once, the rule garden's old sensor follows: no dual path stays.
9. **xtldr joins through a Tail Worker in phase 4**, as a site of its own in `src/sites.ts`: no code in the bot, more than Workers Logs' 7 days, and one `visits`/`logs` surface for everything.
10. **Live aggregates update as visits close**: aggregates are history views, and a path moves only when a visit ends.

Made while building phase 1, each following from the text above:

- **`local` is a site**: Adrian's own processes (daemons, scripts) ship with no web origin and need a home that is not a web property's stream.
- **The bearer names the site.** One ingest token per site (Worker secrets `TOKEN_<SITE>`, values in 1Password item "visits collector"), one read token (`READ_TOKEN`) for the read API, the CLI and the garden admin. Browser batches, which carry no bearer, are refused until phase 2 adds the `Origin` and `service` allowlist.
- **"A span's end that has no parent" is a span opened outside any span of this process**: a root, or a request joined from its caller. The joined request is the case the trigger exists for (its whole trace leaves together), and it has a remote parent.
- **`flushLog`, not `flush`** (`FlushLog`, `flush_log`): ts-utils' root barrel re-exports the logger, where a bare `flush` says nothing.
- **The answer gained `401`, `413` and `415`**, `rejected[].line` counts from 1, and batches may arrive in any order (a writer can have several in flight). All in the README's Shipping section.
- **Retention is by the collector's arrival day**, not the writer's `time`: a wrong clock in a writer can neither keep a row forever nor delete it early. Reads filter and order by arrival too; `time` stays the writer's fact in the line.
- **ts-utils does not retry a failed batch**: one `warnOnce` is the whole failure path. The collector's `(span_id, phase)` dedup is in place for writers that will.
