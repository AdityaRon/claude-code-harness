# H-1B Insights — Design Doc (v0.1)

Status: design only, no code yet. Written 2026-10-15.
Working name: **"H-1B Insights"** (placeholder; pick a name and an X handle before Phase 0).

> This doc lives in `claude-code-harness` only because that is where the work started.
> Once Phase 0 begins it should move to its own repository.

---

## 1. Problem

People on H-1B / H-4 visas, and the people they work with, keep asking the same two kinds of question:

1. **"What is actually true right now?"** Is the $100K fee in effect? Has the 60-day grace period been removed?
   Did something change for H-1B today, or was it actually an H-4 or EAD rule that the headlines called "H-1B news"?
2. **"What do the numbers say?"** Are fewer people applying? Are people leaving? Which employers and states?
   Is the trend speeding up or slowing down?

The answers mostly exist in public data and primary documents (Federal Register, court dockets,
USCIS/DOL/State Department releases). They are scattered, slow to read, and drowned out by
headlines and social posts that confuse **proposed** with **final**, **final** with **effective**,
and **effective** with **blocked by a court**.

### Thesis

> **One place where every H-1B claim has a status label, a date, and a link to the primary source,
> next to dashboards built only from official data.**

Two things set this apart from existing sites (h1bdata.info, myvisajobs, h1bdatahub.com, VisaVerge, law-firm blogs):

- **The status model.** Every policy item is tracked through a fixed lifecycle
  (Proposed → Comment closed → Final → Effective → Enjoined/Vacated …). Each change is backed by a primary source.
  Most competitors write articles; this site keeps a ledger.
- **Honest data.** Each metric says what it measures and what it does not. For example, "registrations fell 38%" says
  nothing about departures. Some questions have no public data, and the site says so instead of guessing.

### Non-goals

- Legal advice for individual cases. The site never says "you should…" about someone's own situation.
- Political commentary. The site stays neutral: status, dates, sources, numbers.
- Being first with a story. Being correct comes first, and being fast is welcome but secondary.

---

## 2. Your questions, and whether data can answer them

This is the most important section. The product promise only works if it is clear which
questions are answerable.

| Question | Answerable? | Best source(s) | Notes |
|---|---|---|---|
| Did H-1B applications go up or down? | **Yes** | USCIS cap registration announcements (annual); DOL LCA disclosure (quarterly) | FY2027: ~211,600 eligible registrations vs ~343,981 for FY2026 (−38.5%), the first year under weighted selection. LCAs are a leading indicator: employers file them before H-1B petitions. |
| By state / county / employer / occupation / wage level? | **Yes** | DOL LCA disclosure files | Worksite state, county, SOC code, wage, and wage level are all in the files. This is the richest public dataset available. |
| Approvals vs denials by employer, new vs continuing employment | **Partly** | USCIS H-1B Employer Data Hub | **The hub has been offline since about March 2026** and the FY24–26 files are missing. We would need archived copies, FOIA requests, and the annual USCIS "Characteristics" report. Treat this as a risk. |
| How many people are leaving? Has it sped up? | **Not directly. Proxies only.** | See §2.1 | No US agency publishes H-1B exits. Anyone quoting a precise "% of H-1Bs who left" is guessing. The site should say this plainly. |
| How many companies paid the $100K fee, and which ones? | **No public data** | FOIA to USCIS/DHS; court filings | USCIS has published no counts. The fee was vacated in court (see §4), so refund litigation may bring numbers out. This makes a strong first post: "Here is what we know, here is what nobody has published, here is our FOIA request." |
| H-4 EAD trends | **Yes, with a lag** | USCIS quarterly "Number of Service-wide Forms" (I-765 by category, c)(26) = H-4 EAD) | Quarterly. Pairs well with the EAD auto-extension rule now in effect. |
| Visa stamping trend by nationality | **Yes** | State Dept monthly nonimmigrant visa issuance by class and nationality | Monthly. H-1B and H-4 issuances are a good near-real-time signal. |
| Wages and prevailing-wage levels | **Yes** | DOL LCA + BLS OEWS | Needed for the weighted-lottery wage-level analysis. |
| Green-card pipeline / backlog | **Yes** | DOL PERM disclosure, monthly Visa Bulletin, USCIS I-140/I-485 data | Explains why many H-1B holders are "stuck" and therefore may leave. |
| Layoffs that start a 60-day clock | **Partly** | State WARN notices, layoffs.fyi | Useful context for the grace-period rule. Not H-1B-specific. |

### 2.1 The "expatriation rate" — how to measure it honestly

There is no direct measurement. Build an **Outflow Signals panel** instead of a single invented number.
Each signal is plotted separately with a one-line explanation of what it does and does not measure:

| Signal | What a drop or rise suggests | Why it is not a departure count |
|---|---|---|
| H-1B petitions for *continuing employment* and *change of employer* (USCIS) | Fewer extensions and transfers suggests fewer people staying | Data lags; currently disrupted by the hub outage |
| LCA **withdrawals** as a share of filings (DOL) | Employers abandoning positions | A withdrawal is not the same as a worker leaving |
| H-1B / H-4 visa issuances (State Dept, monthly) | Fewer stamps abroad suggests less travel or re-entry | Covers people travelling, not the whole population |
| I-94 nonimmigrant admissions (DHS OHSS) | Admissions trend | Counts entries, not people; annual |
| Foreign-born labor force (BLS CPS, monthly) | Macro trend, e.g. about −1M from the March 2025 peak per NFAP's reading of CPS | All foreign-born workers, not H-1B |
| H-4 EAD filings (USCIS I-765 c26) | Household-level stress | Indirect |
| *(Optional, clearly labelled)* Opt-in reader survey | Intent to leave | Self-selected; never mixed into official charts |

Later, a **modelled H-1B population estimate** (stock-and-flow from approvals minus estimated
attrition) could be published as an *estimate* with its methodology open. Only do this if the
methodology section is written first.

---

## 3. Product surfaces

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. POLICY TRACKER      the ledger. Every rule, its status, its      │
│                         timeline, its primary sources, who it        │
│                         actually affects (H-1B? H-4? all EADs?)      │
│  2. DATA EXPLORER       dashboards + slice-and-dice from official    │
│                         data: by year / state / employer / SOC /     │
│                         wage level                                   │
│  3. DISTRIBUTION        X posts, weekly newsletter, alerts           │
│                         ("tell me when the 60-day rule changes")     │
│  4. ASK THE DATA        (later) natural-language → SQL over the      │
│                         marts, with the query and sources shown      │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.1 Policy Tracker (build first)

Each **policy item** has:

- **Title**, plus a plain-English one-liner.
- **Who it affects:** checkboxes for H-1B / H-4 / H-4 EAD / F-1 OPT / L-1 / all EAD holders / employers.
  This directly fixes the "H-4 news reported as H-1B news" problem.
- **Current status** (one of the states below), with an "as of" timestamp.
- **Timeline of events.** Each event has a date, what happened, a **primary source link**
  (Federal Register, court docket, USCIS alert, proclamation), the person who verified it, and the time of verification.
- **"What it means / what it doesn't mean"**: two short bullet lists.
- **Correction log.** Public and append-only. This is how the site earns trust.

**Status lifecycle:**

```
 RUMORED/REPORTED ──► ON REG. AGENDA ──► AT OIRA REVIEW ──► PROPOSED (comment open until X)
                                                                 │
                                                                 ▼
                                                          COMMENT CLOSED
                                                                 │
   EXECUTIVE ORDER / PROCLAMATION ─────────────┐                 ▼
                                               ▼          FINAL RULE PUBLISHED
                                           EFFECTIVE ◄───────────┘
                                               │
                        ┌──────────────────────┼─────────────────────────┐
                        ▼                      ▼                         ▼
           ENJOINED / VACATED (scope,   STAYED PENDING APPEAL     EXPIRED / RESCINDED /
           court, nationwide?)                                    WITHDRAWN
```

The key rule is that **"Proposed" is never shown in the same color as "Effective."**
The X card for every post shows the status badge in large type.

### 3.2 Seed tracker as of 2026-10-15

This is a starting snapshot from a quick web pass. **Every row must be re-verified against the primary
source before publishing.** Several facts below come from law-firm summaries.

| Item | Affects | Status (2026-10-15) | Primary source to verify |
|---|---|---|---|
| $100K payment on new H-1B petitions (Proclamation, Sept 2025; extended Sept 18, 2026 through Sept 21, 2027) | Employers filing new H-1Bs for workers abroad | **Proclamation on the books, but collection vacated or blocked.** D. Mass. ruled for 20 states in June 2026, and the 1st Cir. refused a stay on Jul 24, 2026. N.D. Cal. (*Global Nurse Force v. Trump*) vacated the collection policies in Sept 2026, including under the extension. Appeals continue. | Court dockets (CourtListener), Federal Register (Proclamation 11069, 91 FR 60497) |
| Separate ~$103,265 fee on cap-subject H-1B petitions (DHS rule) | Cap-subject employers | **Proposed.** Comment period closed Sept 24, 2026. No final rule. | 91 FR 54817 |
| Eliminate the discretionary 60-day grace period (H-1B, L-1, O-1, E, TN + dependents) | Laid-off workers and dependents | **Proposed, NOT in effect.** NPRM published Sept 11, 2026. Comments close **Nov 10, 2026**. | federalregister.gov 2026-18631; docket USCIS-2026-0364 |
| End automatic extension of EADs for renewal applicants (incl. H-4 EAD) | **H-4 EAD and other EAD holders, not H-1B workers** | **Final rule, effective Oct 14, 2026.** It finalizes the Oct 30, 2025 interim rule. | Federal Register, Oct 14, 2026 (FR Doc 2026-20955) |
| Rescind H-4 EAD eligibility entirely | H-4 spouses | **Regulatory agenda only ("long-term action").** No proposed rule, no comment period, nothing changed. | Unified Regulatory Agenda (reginfo.gov) |
| Weighted (wage-level) H-1B lottery selection | Cap registrants | **Final and effective** (published Dec 29, 2025, effective Feb 27, 2026). Used for FY2027. | Federal Register Dec 29, 2025 |
| DOL prevailing-wage increase | Employers / wage levels | **Proposed, needs verification**: status and dates not confirmed in this pass | DOL / Federal Register |

The EAD rule shows exactly why this product is needed. A rule that affects **H-4 EAD and other EAD holders**
became effective yesterday, and headlines call it "H-1B news." The tracker's "Affects" field
answers that question in one glance.

### 3.3 Data Explorer (Phase 1 dashboards)

Start with five views. Each needs a "what this measures" note and a "data as of" date.

1. **Demand:** cap registrations per year (FY2020→FY2027) and LCA filings per quarter, broken out by wage level.
2. **Geography:** choropleth of LCAs by worksite state/county; year-over-year change.
3. **Employers:** top sponsors; employer page with LCA history, wages by role, withdrawals.
   *This gives SEO pages: "Does <Company> sponsor H-1B in 2026?"*
4. **Wages:** offered wage vs prevailing wage by SOC and level; share in each weighted-lottery tier.
5. **Outflow signals:** the panel from §2.1.

Slice-and-dice works on the same pre-built marts with filters (year, state, SOC, employer,
wage level). Arbitrary SQL is not needed at the start.

---

## 4. Data sources & ingestion cadence

Use primary sources only. Derivative sites (h1bdata.info, myvisajobs) are built from DOL LCA files,
so go to the same source and do not scrape them, which avoids both ToS and accuracy problems.

| Source | Format / access | Cadence | Used for |
|---|---|---|---|
| **DOL OFLC LCA disclosure** (H-1B, H-1B1, E-3) | XLSX, ~500–700k rows/yr | Quarterly (latest found: FY26 Q3, released Aug 14, 2026) | Employers, worksites, wages, SOC, withdrawals |
| DOL OFLC PERM + Prevailing Wage disclosure | XLSX | Quarterly | Green-card pipeline, wage levels |
| BLS OEWS | CSV/XLSX | Annual | Wage-level thresholds |
| BLS CPS (foreign-born labor force) | API | Monthly | Macro outflow signal |
| USCIS H-1B Employer Data Hub | CSV (**currently offline**) | Annual | Approvals and denials by employer |
| USCIS cap registration announcements | Web page | Annual (Mar–Jul) | Registrations, selections |
| USCIS "Characteristics of H-1B Workers" report to Congress | PDF | Annual (FY25 published Apr 2026) | Country, education, age, occupation |
| USCIS quarterly form-volume data (I-129, I-765 by category, I-140, I-485) | XLSX | Quarterly | H-4 EAD filings, pipeline |
| State Dept NIV issuances by class & nationality | PDF/XLSX | Monthly | Visa-stamp trend |
| State Dept Visa Bulletin | HTML | Monthly | Green-card backlog |
| DHS OHSS (I-94 admissions, Yearbook, Entry/Exit Overstay report) | XLSX/PDF | Annual | Admissions, overstays |
| Census ACS | API | Annual | Foreign-born by state/occupation |
| **Federal Register API** | JSON, free, no key | Poll hourly | New proposed/final rules, proclamations (agencies: USCIS, DHS, DOL, State, EOP) |
| **regulations.gov API** | JSON, free key | Daily | Comment deadlines and **comment counts**, a nice metric |
| **reginfo.gov** (OIRA review + Unified Agenda) | XML/HTML | Daily | Early warning: rules under White House review |
| **CourtListener / RECAP API** | JSON, free key | Daily | Litigation dockets (fee cases, etc.) |
| USCIS newsroom + alerts, DOL OFLC announcements | RSS/HTML | Hourly | Agency guidance |
| State WARN notices, layoffs.fyi | HTML/CSV | Weekly | Layoff context |
| **FOIA requests** (USCIS: $100K fee payments and exceptions by employer; Employer Data Hub FY24–26) | Manual | One-off | Fills gaps. Publishing the request is itself content. |

**Archive every raw file you download** (object storage, with checksum and fetch date).
Government pages disappear, as the Employer Data Hub just did. Keeping the archive is part of the value.

---

## 5. Architecture (kept simple: no heavy AWS)

```
                      ┌─────────────────────────────┐
  GitHub Actions cron │  ingest/<source>.py         │  one small module per source
  (hourly/daily/      │  fetch → archive raw → parse│
   quarterly)         └──────┬───────────────┬──────┘
                             │               │
                 raw files   ▼               ▼  rows
                 ┌────────────────┐   ┌──────────────────────────┐
                 │ Cloudflare R2  │   │ Postgres (Neon or        │
                 │ (cheap, no     │   │ Supabase)                │
                 │  egress fees)  │   │  raw_* → staging → marts │
                 └────────────────┘   │  (SQL views / matviews)  │
                                      └────────────┬─────────────┘
  ┌──────────────────────────────┐                 │
  │ Policy monitors (FR API,     │  candidate      │
  │ reginfo, CourtListener,      │──events──► review queue (admin page)
  │ USCIS RSS)                   │   + LLM draft         │ you approve / edit
  └──────────────────────────────┘                       ▼
                                      policy_event published
                                           │
              ┌────────────────────────────┼─────────────────────────┐
              ▼                            ▼                         ▼
     Next.js site on Vercel        X post (card image)     Newsletter (weekly digest)
     (tracker, dashboards,         via X API, or queued    via beehiiv / Buttondown
      employer/state pages)        for manual post         + alert emails
```

### Choices and reasons

| Concern | Pick | Why |
|---|---|---|
| Web app | **Next.js on Vercel** | Free tier covers launch. Static/ISR pages give strong SEO for employer and state pages. Easy previews. |
| Database | **Postgres (Supabase or Neon)** | About 10 years of LCA data is ~6M rows, comfortable for Postgres with indexes and materialized views. Supabase adds auth and storage when accounts are needed. |
| Analytics engine | Same Postgres at first | Add DuckDB over Parquet in R2 later, only if dashboards get slow. |
| Scheduled jobs | **GitHub Actions cron** | Free, versioned, logs included, no servers. Upgrade to a small worker (Fly.io/Render) only if needed. |
| Raw archive | **Cloudflare R2** | Cheap, S3-compatible, no egress fees. |
| Charts | Observable Plot / ECharts / Recharts | Choose at Phase 1. |
| Site analytics | **Vercel Web Analytics** or **Plausible** (privacy-friendly), with **PostHog** for funnels later | Visitors, top pages, signup conversion. |
| Auth (Phase 3) | Supabase Auth or Clerk | Needed only for alerts, saved views, and the paid tier. |
| Payments (Phase 3) | Stripe | Standard. |
| LLM assist | Claude API | Summarizes new Federal Register docs and court orders, proposes status transitions, drafts posts. **Never auto-publishes.** |

**Estimated cost at launch:** about $0–30/month (domain, possibly Neon/Supabase paid tier, LLM calls).
Costs grow with traffic, not with data size.

### "Is Vercel good for monetizing?"

Vercel only hosts the site. Monetization comes from Stripe (subscriptions), newsletter sponsorships, and B2B
deals, and none of them depend on the host. Vercel works well here because the site is mostly
pre-rendered pages, which keeps it fast and cheap. Watch out for **serverless function time** if you
run heavy queries on each request. Use pre-computed marts and cached pages instead.

### Core data model (sketch)

```
policy_item(id, slug, title, one_liner, affects[], current_status, status_as_of)
policy_event(id, policy_item_id, event_date, new_status, summary,
             source_url, source_kind[primary|secondary], verified_by, verified_at)
correction(id, policy_item_id, made_at, what_changed, why)
source_snapshot(id, source, url, fetched_at, sha256, r2_key)    -- archive ledger

employer(id, canonical_name, fein?, hq_state)                    -- see risk: entity resolution
employer_alias(alias_name, employer_id)
lca_case(case_no, employer_id, fiscal_year, quarter, status, worksite_state,
         worksite_county, soc_code, wage_offered, wage_unit, pw_level, decision_date, ...)
uscis_employer_year(employer_id, fiscal_year, new_approvals, new_denials,
                    continuing_approvals, continuing_denials, ...)
visa_issuance_month(month, visa_class, nationality, count)
form_volume_quarter(quarter, form, category, received, approved, denied, pending)
labor_force_month(month, nativity, employed, unemployed, ...)
```

**Employer entity resolution** (for example, "Amazon.com Services LLC", "Amazon Web Services Inc", and "AMAZON DEV CENTER")
is the hardest data problem here. Start with normalized names plus a hand-curated alias table for the top
500 sponsors, which cover most of the volume.

---

## 6. Distribution and engagement

Start small, as you said. The order matters.

1. **X handle (day 1).** The format: one policy item per post, a **status card image** (large badge:
   "PROPOSED — NOT IN EFFECT", plus the date and source), and the primary-source link in the reply.
   Recurring series:
   - **"Status check"**, when a headline goes viral: *"Is X in effect? No. Here's the doc."*
   - **"Not H-1B"**, correcting misattributed news (H-4/EAD/OPT).
   - **"Chart of the week"** from the Data Explorer.
   - **"Deadline"** reminders for comment periods (Nov 10 for the 60-day rule).
2. **Weekly newsletter** (beehiiv or Buttondown). Five items: status changes, one chart, upcoming deadlines,
   corrections. Your owned audience, independent of the X algorithm.
3. **SEO pages.** Auto-generated employer, state, and occupation pages from LCA data. This is the
   long-run traffic engine, because people search "<company> H-1B sponsor 2026."
4. **Communities.** Post in r/h1b and r/immigration, on LinkedIn, and in **Telegram/WhatsApp channels**
   (heavily used by the Indian diaspora, the largest H-1B group). Answer questions with tracker links.
5. **Alerts** (Phase 3). "Email me when the status of X changes." Highest-intent feature, and the natural paid hook.

**No human presenter needed.** If video becomes worthwhile later, a 60-second auto-generated
"status card" reel built from the same data could test the channel cheaply.

---

## 7. Monetization (later, but decide the shape now)

Ranked by realism for a small, data-first operation:

| # | Model | Notes |
|---|---|---|
| 1 | **Newsletter sponsorships** | Immigration law firms, NRI banking/remittance, relocation, international tax, health insurance. Works at a few thousand subscribers, because the audience is high-income and narrowly targeted. |
| 2 | **Freemium "Pro"** (~$5–10/mo) | Status-change alerts, employer deep-dives, CSV export, saved views, historical comparisons. The free tier stays generous, since trust is the product. |
| 3 | **B2B data/API and reports** | Immigration law firms, HR/global mobility teams, journalists, researchers. Clean, entity-resolved employer data is the asset. Higher revenue, fewer customers. |
| 4 | Attorney directory / featured listings | Use flat-fee listings, **not per-referral fees**, because lawyer-referral rules vary by state. Keep it clearly separate from editorial content. |
| 5 | Display ads | Low revenue and hurts credibility. Skip, or use only on SEO pages. |
| 6 | X creator revenue sharing | Requires Premium and meeting follower/impression thresholds, and payouts are small and unpredictable. Treat any income as a bonus, not a plan. |

**Recommended path:** free everything → newsletter with a sponsor slot at ~2–5k subscribers →
Pro alerts → B2B once the employer dataset is clean.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| Being wrong about a status damages trust | Primary source required for each status change; a human approves every publish; public correction log; "as of" timestamp on everything. |
| Seen as legal advice | Prominent disclaimer; no individual-case advice; "consult an attorney" links. Have a lawyer review the terms of service once. |
| LLM hallucination in summaries | LLM output only goes to a review queue; quotes are linked to source text; never auto-post. |
| Data gaps (Employer Data Hub offline, no exit data) | Say so openly; FOIA; archive everything; the Outflow Signals panel instead of a single number. |
| Employer name messiness | Alias table for top sponsors; show the raw names on employer pages. |
| Political heat | Neutral tone; status and data only; no opinion columns. |
| **Founder burnout** (the real risk) | Automate ingestion and monitoring first; keep publishing to a ~15-minute daily review; one weekly newsletter. |

---

## 9. Phased plan

| Phase | Scope | "Done" when | Effort (part-time) |
|---|---|---|---|
| **0 — Ledger + handle** | Pick name/handle. Static tracker page (hand-written JSON/Markdown for 7 seed items in §3.2, each verified against the primary source). Status-card image template. Start posting. File the two FOIA requests. | 7 items live with primary sources; 10 posts out | 1–2 weeks |
| **1 — Data v1** | Postgres + R2. LCA ingestion FY2020→FY26Q3. Cap registration history. State Dept monthly issuances. 5 dashboards from §3.3. Employer and state pages. | Dashboards reproducible from a clean rebuild; numbers spot-checked against DOL "Selected Statistics" PDFs | 3–4 weeks |
| **2 — Monitors + newsletter** | Federal Register / reginfo / CourtListener / USCIS monitors → review queue → publish → auto-drafted X post and newsletter section. Site analytics. Outflow Signals panel. | A new FR document on H-1B appears in the queue within 1 hour | 3–4 weeks |
| **3 — Accounts + alerts + Pro** | Auth, status-change alerts, saved views, CSV export, Stripe. | First paying user | 3–4 weeks |
| **4 — Ask the data** | Natural-language questions → SQL over the marts, with the query and sources shown. | Answers 20 benchmark questions correctly | later |

### Metrics to watch

- Phase 0–1: followers, newsletter subscribers, and **time from primary-source publication to status update on the site**.
- Phase 2+: weekly returning visitors, alert signups, and newsletter open rate.
- Trust: number of corrections, and how long each took to fix. Publish both numbers.

---

## 10. Open decisions for you

1. **Name, domain, and X handle.** Neutral and data-sounding rather than activist.
2. **Scope:** H-1B only, or "employment-based immigration" (H-1B, H-4, L-1, OPT, green card) from day 1?
   Recommendation: brand it around H-1B, but let the tracker's "Affects" field cover everything nearby.
3. **Identity:** your name on it, or anonymous? A named person helps credibility with journalists and sponsors.
4. **Newsletter platform:** beehiiv (built-in sponsorship marketplace) or Buttondown (simple, developer-friendly).
5. **Repo:** move this into its own repository before Phase 0 code starts.
