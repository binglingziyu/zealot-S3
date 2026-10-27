# Zealot UI design system

Zealot is a developer workspace for distributing application builds. The UI prioritizes readable release data, clear actions and predictable navigation. Implemented with the existing Rails, Slim, Turbo, Stimulus, Bootstrap and AdminLTE stack.

## Source of truth

`app/assets/stylesheets/theme.scss` owns the product tokens, shared components and responsive page styles. It is loaded after framework and legacy styles. `_button.scss` retains only compatibility variables required by legacy status cards; avoid adding new component overrides there.

| Token | Light | Dark | Purpose |
| --- | --- | --- | --- |
| `--zl-canvas` | `#f5f7fb` | `#101620` | Workspace background |
| `--zl-surface` | `#ffffff` | `#182130` | Cards, navigation, forms |
| `--zl-surface-raised` | `#ffffff` | `#1d293a` | Raised content |
| `--zl-subtle` | `#eef2f8` | `#222f43` | Table headings, secondary controls |
| `--zl-border` | `#dce3ee` | `#334158` | Component boundaries |
| `--zl-text` | `#17243b` | `#e8eef9` | Primary text |
| `--zl-muted` | `#53647d` | `#a8b6cc` | Supporting text |
| `--zl-primary` | `#315fe9` | `#98b7ff` | Links, selected items, focus |
| `--zl-accent-bg` | `#eaf0ff` | `#253958` | Selected item background |

Primary filled actions use `#315fe9` with white text in both modes. Destructive actions retain red. Status badges retain their semantic meaning. Do not use raw page-specific colors for new components.

## Typography and spacing

Use local system fonts, with PingFang SC and Microsoft YaHei fallbacks. No external font service is required. Body text is 15px with a 1.6 line height, forms 15px, supporting labels 12–14px and page headings 25px/21px. Metrics use tabular numerals. Allow long application names and metadata values to wrap.

Use a 4px spacing scale: 4, 8, 12, 16, 20, 24, 28 and 32px. Cards have a 14px radius, controls 8px, and icon tiles 8–13px. Card shadows are subtle; component hierarchy comes primarily from spacing, surface colors and borders.

## Shared shell and components

The desktop sidebar is 248px wide, the header is 64px high. Page headers pair one h1 and a short description with primary actions. The sidebar button exposes its expanded state; mobile navigation supports Escape and overlay dismissal after Turbo navigation. The content area uses 28px gutters on desktop and 16px on mobile. Cards, tables, inputs, buttons, dropdowns, pagination and modals share semantic colors and focus rules.

Buttons show hover and focus states. Input errors continue using Bootstrap/Simple Form feedback. Existing disabled, busy, confirmation and Turbo states remain functional. Tables scroll inside their responsive wrappers; avoid page-level horizontal scrolling. Informational links and muted text must meet a 4.5:1 contrast target against their surfaces.

The header Appearance menu supports Light, Dark and System. A per-user browser-local choice overrides the account/site default on that browser. Without an override, the saved account/site setting applies. System mode tracks operating-system changes live. The early theme bundle sets the color scheme before stylesheet rendering. Storage failures fall back to the configured default and do not prevent rendering.

## Representative pages

- Dashboard: one responsive statistics grid at every width, consistent metric cards, compact release feed and empty state. The former duplicate mobile statistics are removed.
- Application catalog: responsive cards with compact identity, creation time and three aligned counters. Application names use a two-line clamp with their full text retained for accessibility and in the title. Search and sorting preserve the current active/archived route. The search field stays available after no results.
- Channel detail: identity summary with the upload action, release activity as primary content, configuration and channel navigation as secondary content. Secondary webhook configuration uses a native details/summary disclosure. Long links, bundle identifiers and keys wrap.

## Responsive and accessibility rules

At 375px the content uses one catalog column and two metric columns. At 768px the catalog uses two columns; at 1200px three; at 1400px four. Statistics use four columns from 1200px. The existing AdminLTE sidebar breakpoint remains 992px.

Keep native keyboard navigation, a visible skip link, an explicit main landmark, labels for icon controls and visible focus outlines. Selected theme choices expose their state. Mobile buttons and pagination have at least 44px height. Honor `prefers-reduced-motion`; do not add entrance animations to data or pagination.

## Extending the design

Prefer shared tokens and component classes. Keep workflow logic and authorization in existing Rails helpers/controllers. Preserve Turbo frame IDs when modifying templates. Match new component states in both themes. Inspect representative screens at 375, 768, 1024 and 1440px before delivery.
