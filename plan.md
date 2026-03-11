# Anna's Archive KOReader Plugin Analysis And Improvement Plan

## Execution Model

- Phase 0 is environment and repository setup.
- Phases 1 through 5 should each be handled by a dedicated subagent.
- Each phase should land as its own conventional commit.

## Summary

The immediate reason `annas.koplugin` replaces `zlibrary.koplugin` in the KOReader menu is that this plugin still registers itself under Z-library identifiers in multiple places. The visible menu overwrite happens because both plugins can write to the same main-menu slot key, but the deeper problem is that the Anna plugin still reuses the Z-library Lua namespace, action IDs, cache path, settings keys, and credentials filename.

This means the two plugins are not isolated from each other. Even if the menu entry collision is fixed, they can still interfere through shared `require(...)` module names and shared persisted settings.

## Why The Plugins Replace Each Other

### 1. Main menu entry collision

The Anna plugin registers its main menu entry as `menu_items.zlibrary_main` in [main.lua](main.lua#L75).

If the Z-library plugin also uses `zlibrary_main`, whichever plugin initializes later overwrites the other entry in KOReader's menu table.

### 2. Dispatcher action collision

The Anna plugin registers the action `zlibrary_search` with event `ZlibrarySearch` in [main.lua](main.lua#L34).

If both plugins expose the same action ID and event name, gesture bindings and action dispatch are not isolated.

### 3. Lua module namespace collision

The Anna plugin still requires nearly everything from the `zlibrary.*` namespace, for example in [main.lua](main.lua#L11) and throughout the `zlibrary/` directory.

That is a structural coexistence bug. Lua caches modules by their `require(...)` name, not by plugin folder. If both plugins load `zlibrary.ui`, `zlibrary.config`, `zlibrary.gettext`, and so on, one plugin can end up reusing the other plugin's already-loaded module.

### 4. Shared persisted settings

The Anna plugin still stores settings under Z-library keys in [zlibrary/config.lua](zlibrary/config.lua#L8), [zlibrary/config.lua](zlibrary/config.lua#L13), [zlibrary/config.lua](zlibrary/config.lua#L16), and related lines.

Examples:

- `zlibrary_search_languages`
- `zlibrary_search_extensions`
- `zlibrary_search_order`
- `zlibrary_download_dir`
- `zlibrary_test_mode`

If both plugins are installed, each plugin can read or overwrite the other's settings.

### 5. Shared credentials file name

The plugin still loads `zlibrary_credentials.lua` via [main.lua](main.lua#L44) and defines that filename in [zlibrary/config.lua](zlibrary/config.lua#L25).

That creates another configuration collision and also misleads users, because Anna's Archive does not use the same credential model as the original Z-library plugin.

### 6. Shared cache namespace

The plugin cache directory is still `.../cache/zlibrary` in [zlibrary/cache.lua](zlibrary/cache.lua#L14).

So even runtime cache data is not isolated.

## Current Configuration On Kindle

### What can actually be configured from the device UI

From the file browser in KOReader:

1. Open `Search`.
2. Open `Anna's Archive`.
3. In the search dialog you can configure:
   - sort order via [zlibrary/ui.lua](zlibrary/ui.lua#L425)
   - languages via [zlibrary/ui.lua](zlibrary/ui.lua#L433)
   - formats via [zlibrary/ui.lua](zlibrary/ui.lua#L441)
4. Open `Settings` from the same dialog via [zlibrary/ui.lua](zlibrary/ui.lua#L451).
5. In settings, the only clearly exposed persistent option is the download directory via [zlibrary/ui.lua](zlibrary/ui.lua#L142).

There is also a per-download Wi-Fi toggle persisted from the post-download dialog in [zlibrary/ui.lua](zlibrary/ui.lua#L652) and [zlibrary/ui.lua](zlibrary/ui.lua#L667).

### What is present in the repository but misleading or not useful for Anna's Archive

- `zlibrary_credentials.lua` is still shipped in the root and documented as if Anna needed Z-library credentials.
- The Chinese README is still a Z-library README and points users to `zlibrary.koplugin` paths and account setup in [README.zh-CN.md](README.zh-CN.md#L1) and [README.zh-CN.md](README.zh-CN.md#L53).
- Old login, base URL, and RPC/API concepts still exist in code, even though Anna search is now done by scraping and mirror probing.

### Practical Kindle configuration guidance today

If you sideload the plugin as-is, the safe configuration path is:

1. Put the folder at `koreader/plugins/annas.koplugin`.
2. Restart KOReader.
3. Configure search filters from the Anna search dialog.
4. Set the download directory from the Anna settings dialog.
5. Ignore `zlibrary_credentials.lua` unless you are debugging leftover code paths.
6. Only use the README DNS workaround if Anna mirrors are blocked on your network.

The DNS workaround in the README is operationally risky on Kindle because it edits system files and may require remounting the root filesystem writable. Router-level DNS changes are safer than modifying the device itself.

## Shortcomings In The Current Extension

### Coexistence and namespacing

- The plugin is not namespaced as `annas.*`; it still uses `zlibrary.*` modules everywhere.
- Menu, action, settings, credentials, logs, and cache names are still Z-library flavored.
- This makes side-by-side installation with the original Z-library plugin unreliable by design.

### Mixed old and new architecture

- Initial search uses `scraper(query)` in [main.lua](main.lua#L492), but pagination still tries to call `Api.search(...)` in [main.lua](main.lua#L556).
- Login and account-session flows are still present in [main.lua](main.lua#L438) even though Anna's Archive access is described as account-free in the README.
- The repository contains both the older API-oriented Z-library abstraction and the newer Anna scraping layer, without a clean boundary.

### Search flow bug

- The loading dialog is created after the synchronous scrape already happened in [main.lua](main.lua#L492) and [main.lua](main.lua#L494).
- The function then calls `AsyncHelper.run(task, loading_msg)` with an undefined `task` in [main.lua](main.lua#L513).
- This should be treated as a real bug, not only cleanup.

### Scraper fragility

- Search depends on scraping Anna's HTML structure and hardcoded class fragments in [src/scraper.lua](src/scraper.lua#L68) and [src/scraper.lua](src/scraper.lua#L413).
- Mirror discovery depends on scraping Wikipedia in [src/scraper.lua](src/scraper.lua#L87) and [src/scraper.lua](src/scraper.lua#L90).
- The domain cache is stored as `annas_domains_cache.txt` in the current working directory in [src/scraper.lua](src/scraper.lua#L5), instead of a KOReader data/cache path.

### Platform assumptions

- The scraper and updater shell out to `curl`, `wget`, `which`, `mkdir -p`, `unzip`, `cp -ru`, and `rm -rf` in [src/scraper.lua](src/scraper.lua#L221), [src/scraper.lua](src/scraper.lua#L270), [src/update.lua](src/update.lua#L23), [src/update.lua](src/update.lua#L36), and [zlibrary/ota.lua](zlibrary/ota.lua#L194).
- That is brittle, hard to test, and inconsistent across KOReader targets.

### Documentation and UX drift

- The English README partly describes Anna-specific behavior, but the Chinese README still documents the Z-library plugin.
- UI strings and internal names still say `Zlibrary` or `Z-library search` in multiple places, including [main.lua](main.lua#L34).
- Settings are limited for an extension that depends heavily on network mirrors and anti-bot conditions.

## Improvement Plan

### Phase 0: Environment and setup

1. Install a minimum useful Windows development toolchain for this repository.
2. Verify `git`, `curl`, `tar`, `lua`, `luajit`, `luarocks`, and editor support commands from a clean shell.
3. Add lightweight repository-side setup support so later phases can execute reliably.
4. Record the expected setup flow in the README and workspace recommendations.

Acceptance criteria:

- A contributor on Windows can install and verify the local toolchain without guessing package names.
- The repository contains a repeatable verification entry point for future phase work.

### Phase 1: Fix coexistence first

1. Rename the internal Lua namespace from `zlibrary.*` to `annas.*`.
2. Rename the local plugin class and log prefix from `Zlibrary` to `Annas`.
3. Change the main menu key from `zlibrary_main` to an Anna-specific key.
4. Change the dispatcher action and event names from `zlibrary_search` and `ZlibrarySearch` to Anna-specific identifiers.
5. Move cache and settings keys to `annas_*` names.
6. Rename the credentials/config override file if one is still needed.

Acceptance criteria:

- `annas.koplugin` and `zlibrary.koplugin` can both appear in the Search menu.
- Both plugins can keep independent settings and gestures.
- Installing one plugin does not alter the other's runtime behavior.

### Phase 2: Remove dead Z-library paths

1. Delete or isolate old login, session, RPC, and Z-library API code that Anna no longer uses.
2. Remove any `baseUrl`, email, and password configuration paths unless there is a real Anna-side use case.
3. Drop unreachable or misleading UI for Z-library-specific concepts.
4. Make the README and translation files match the actual product.

Acceptance criteria:

- A fresh user can configure the plugin without seeing any Z-library terminology.
- No Anna code path depends on Z-library credentials or API URLs.

### Phase 3: Stabilize search and download behavior

1. Fix `performSearch` so the scrape runs through `AsyncHelper.run` correctly.
2. Remove the stale `Api.search(...)` pagination branch or replace it with Anna-compatible pagination.
3. Move the Anna domain cache to a KOReader cache/data directory.
4. Replace `print(...)` debugging with structured logger calls.
5. Add better user-facing error messages for DNS blocks, mirror failures, and DDoS/anti-bot responses.

Acceptance criteria:

- Search shows a loading state before network work starts.
- Pagination does not fall back into obsolete Z-library API code.
- Domain cache survives restarts without depending on current working directory.

### Phase 4: Reduce shell-command dependency

1. Prefer KOReader/Lua-native HTTP and filesystem APIs over `io.popen(...)` and `os.execute(...)`.
2. Keep shell fallbacks only when strictly necessary and detect platform capability explicitly.
3. Rework OTA update logic to avoid destructive shell commands and hardcoded plugin paths.

Acceptance criteria:

- Core search/download functionality works without assuming desktop-like Unix tools.
- Update behavior is safe on Kindle and other KOReader targets.

### Phase 5: Improve user configuration on Kindle

1. Add an Anna-specific settings screen that exposes all supported persistent options in one place.
2. Expose mirror strategy, retry count, timeout policy, and optional preferred source configuration.
3. Document the recommended DNS workaround as router-first, device-second.
4. Replace the stale Chinese README with an Anna-specific translation.

Acceptance criteria:

- A Kindle user can configure the plugin entirely from KOReader without reading source files.
- The README matches the actual UI and behavior.

## Recommended Execution Order

1. Phase 0 environment and setup.
2. Namespacing and side-by-side installation fixes.
3. Search flow bug fix and pagination cleanup.
4. Removal of dead Z-library configuration and docs.
5. Cache/storage cleanup.
6. OTA and shell-command hardening.
7. UX and documentation improvements.
