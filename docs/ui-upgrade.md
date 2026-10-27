# UI modernization

The UI continues to use Rails 8.1, Slim/ERB, Turbo, Stimulus, Bootstrap 5.3, AdminLTE 4 and Sass. The upgrade provides a product-owned theme above the framework styles. No new package dependency or database migration is required.

## Delivered scope

| Phase | Implementation |
| --- | --- |
| 1 — Theme foundation | Shared light/dark surface, text, border, link, focus, spacing and radius tokens; system font stack; component and responsive guidance in `design-system/zealot/MASTER.md`. |
| 2 — Application shell | Sidebar, header, page heading and actions, content gutters, footer, browser-local appearance selection, early theme application, theme-aware logo, keyboard skip link and sidebar accessibility state. |
| 3 — Shared components | Cards, tables, pagination, forms, buttons, dropdowns, modals, badges, selected items, hover/focus and reduced-motion behavior. |
| 4 — Representative workflows | Responsive dashboard statistics and release feed, compact application catalog with aligned counters and long-name handling, channel identity/upload summary, release activity and collapsible secondary configuration. |
| 5 — Adaptation and review | Desktop/mobile layout checks, both themes, contrast checks and browser interaction acceptance with screenshots and a machine-readable report. |

The shared theme also applies to groups, object storage, debug files, users and settings. These pages retain their existing workflow and are included in responsive smoke coverage.

## Interaction fixes

- Statistics now use a single grid at every screen size. The previous desktop/mobile variants left statistics missing at some widths.
- Application search remains available when there are no matches. Archived search/sorting retains the archived route, and sort selections preserve the search term.
- Catalog actions check the app being rendered. Icon actions have accessible names.
- Channel pagination updates browser history through the Turbo frame's `advance` action.
- Secondary channel webhook configuration uses native `details`/`summary` for stable mouse and keyboard expansion.
- Sidebar buttons have one application event path instead of overlapping AdminLTE and application click handling. Turbo navigation restores the overlay and keyboard dismissal; repeated toggle clicks preserve the current state.
- The localized skip link bypasses Turbo for native in-page keyboard focus. Framework-generated duplicate skip links are removed.

## Appearance behavior

Light, dark and system choices are stored locally per signed-in user (or guest) on the browser. A local choice takes precedence over the account/site default. System mode responds to operating-system changes without reloading. The theme initializer handles unavailable browser storage. The normal account/site appearance setting remains the default when there is no local choice.

Application icons retain a white base in dark mode because uploaded icon assets and the fallback icon can contain dark marks. The brand logo switches separately according to the actual selected theme.

## Validation

Build JavaScript with `npm run build` and CSS with `npm run build:css`. Precompile using the existing Rails asset workflow. The current Sass dependencies emit legacy import/function deprecation messages; the product stylesheet adds no new dependency.

Browser acceptance is documented in `test/ui/README.md` and implemented in `test/ui/theme.cjs`. It uses a disposable PostgreSQL database and the existing container runtime, renders real Rails responses, and tests both themes at 375, 768, 1024 and 1440px for the three representative pages. Five secondary pages are checked at 375 and 1440px in both themes. The script checks page-level overflow, primary/muted/link color contrast, appearance persistence, live system theme, search, sort, modal behavior, pagination, upload navigation, empty states and keyboard/mobile navigation.

Local review artifacts are written to ignored `tmp/ui-review/`: 24 representative screenshots, modal/mobile navigation screenshots and `report.json`. A passing report includes `complete: true`. Fixtures use placeholder package files, so this UI suite does not claim to verify real binary upload, package parsing or device installation.

## Acceptance result — 2026-10-17

Passed in the isolated local preview runtime: **44 layout combinations**, **12 text-color contrast pairs** (minimum **4.96:1**), and **13 interaction/rendering checks**. The successful browser run reported no JavaScript errors or same-origin HTTP failures. JavaScript/CSS builds, Rails asset precompilation, source syntax checks and `git diff --check` passed. The built asset manifest contains nonempty `application.css`, `application.js` and `theme.js` entries.

The final screenshots were visually reviewed for light/dark surfaces, catalog alignment and long names, channel hierarchy, narrow-screen statistics and mobile navigation. Results are local to this workspace; the deployed application has not been updated.

## Deployment

Rebuild the application's container with the existing `Dockerfile.s3` workflow to include the changed views and freshly built assets. Include the generated `theme.js` asset. The existing Docker build compiles all JavaScript entrypoints, so no extra runtime configuration is needed.

## 生产部署（2026-10-17）

已部署至 https://zealot.dev.ihubin.com ，镜像 `zealot-s3:ui-20261017`，ID `sha256:d03cec3f1d9a41b97b3ed60d9805abb5f9418d75e72ff9d12c414edfd1b52a0b`。生产 healthy，公网健康、管理员登录、三个代表页面、深色主题持久化、375px 布局通过检查，未发现浏览器脚本或同源资源错误。schema 未变化。服务器回滚归档为 `/Users/hubin/docker-zealot/backups/pre-ui-20261017-225111/`，恢复其中 Compose 并重建应用容器即可回滚本次 UI，无需覆盖数据库。
