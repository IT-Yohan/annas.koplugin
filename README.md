# [KOReader Annas Plugin](https://github.com/fischer-hub/annas.koplugin)

**Disclaimer:** This plugin is for educational purposes only. Please respect copyright laws and use it responsibly.

This KOReader plugin searches Anna's Archive and downloads files through Anna's public mirror pages. It does not use a Z-library account flow, RPC endpoint, base URL override, or stored login session. Search and download work through scraping, so they may break when Anna's Archive changes its HTML or source-link layout.

Big thanks to the maintainers of the [KOReader Zlibrary plugin](https://github.com/ZlibraryKO/zlibrary.koplugin), which inspired much of the UI structure, and to the authors of [KindleFetch](https://github.com/justrals/KindleFetch), which informed parts of the scraping approach.

The plugin was tested on KOReader installed on a Kindle Paperwhite 11th generation.

## Installation

1. Download the `annas.koplugin.zip` asset from the [latest release](https://github.com/fischer-hub/annas.koplugin/releases/latest).
2. Extract it and ensure the directory name is exactly `annas.koplugin`.
3. Copy `annas.koplugin` to `koreader/plugins` on your device.
4. Restart KOReader.

## Build And Package

There is no compile step for this plugin.

KOReader loads it directly from Lua source files, so the practical "build" for local use is:

1. Validate the Lua files.
2. Package the plugin directory into a ZIP with `annas.koplugin` as the archive root.

Local validation commands:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-env.ps1
lua -e "local p=io.popen('git ls-files *.lua annas/*.lua src/*.lua'); for f in p:lines() do assert(loadfile(f), 'loadfile failed: '..f) end; p:close(); print('Lua syntax validation passed')"
```

Local packaging command:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-plugin.ps1
```

That produces:

- `dist/annas.koplugin.zip`

The ZIP contains a single top-level directory named `annas.koplugin`, which is the layout KOReader expects.

## Install From Source Or Local Package

### Option 1: Install from source checkout

1. Copy this repository folder to your device.
2. Ensure the copied folder is named exactly `annas.koplugin`.
3. Place it under `koreader/plugins`.
4. Restart KOReader.

### Option 2: Install from locally packaged ZIP

1. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\package-plugin.ps1
   ```

2. Extract `dist/annas.koplugin.zip`.
3. Copy the extracted `annas.koplugin` directory to `koreader/plugins` on the device.
4. Restart KOReader.

### Result on device

After restart, open the KOReader file browser, then go to `Search` and look for `Anna's Archive`.

If `zlibrary.koplugin` is also installed, both plugins should now appear separately.

## Windows Development Setup

Phase 0 uses the smallest Windows toolchain that is useful for local work on this repository:

- `git`, `curl`, and `tar`
- `luajit` for a runtime that is close to KOReader's LuaJIT-based environment
- `lua` and `luarocks` for generic Lua tooling
- `lua-language-server` for editor diagnostics and navigation

The current repo setup was verified with `winget`:

```powershell
winget install --id DEVCOM.LuaJIT --accept-source-agreements --accept-package-agreements --silent
winget install --id DEVCOM.Lua --accept-source-agreements --accept-package-agreements --silent
winget install --id LuaLS.lua-language-server --accept-source-agreements --accept-package-agreements --silent
```

After installation, open a new shell so the updated `PATH` is visible, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-env.ps1
```

Notes:

- `luajit` is the best local match for KOReader plugin work.
- `lua` and `luarocks` are included to make future tooling installs possible.
- Native LuaRocks packages that compile C extensions may still require a separate MinGW or MSVC build toolchain on Windows.
- Recommended VS Code extensions for this repo live in `.vscode/extensions.json`.


## Usage

1. Ensure you are in the KOReader file browser.
2. Open the `Search` menu.
3. Select `Anna's Archive`.
4. Enter a query, then optionally adjust sort order, languages, and formats directly in the search dialog.
5. Open a search result.
6. Tap the format line to download the file.

To configure persistent Anna-specific options in one place:

1. Open `Search`.
2. Select `Anna's Archive`.
3. Tap `Settings`.

The settings screen now includes:

- Search order, languages, and formats
- Download directory
- Wi-Fi auto-off after download
- Mirror strategy for Anna mirror probing
- Automatic retry count for transient network failures
- Preferred download source for LibGen-backed downloads
- Timeout policy presets, plus advanced per-operation timeout editing
- Update check

Notes:

- There is no account setup step.
- There is no `annas_credentials.lua` override file anymore.
- Recommended and most-popular Z-library-era browsing paths were removed because Anna's Archive does not use that API flow in this plugin.
- The current download flow still depends on supported LibGen mirrors exposed through Anna's Archive result pages.

## DNS Settings

**Only change DNS if Anna's Archive repeatedly fails on your network.**

You only need to do this if Anna’s Archive repeatedly does not work, for example:

* Downloads not working
* No results found (even when searching for something general)
* “All protocols failed” errors

### Recommended order

1. Try a router-level DNS change first.
2. Only use device-level edits if you cannot change the router and you understand the risks.

Router-level DNS changes are safer on Kindle and Kobo because they avoid editing system files on the reader.

### Router-first fix

If you control your router, prefer changing DNS there instead of modifying files on the reader. Search for:

> **Change DNS to 1.1.1.1 on {Your Router Model}**

and follow the instructions for your hardware.

### Device-level fix (Kobo & Kindle, only if needed)

Warning:

- Device-level DNS edits can be overwritten by updates or networking scripts.
- Some Kindle setups require remounting the root filesystem writable.
- If router DNS is available, use that instead.

Follow these steps:

1. Open an SSH session using KOReader.
   Go to:
   **Settings → Network → SSH Server → No Password** (for simplicity).

2. You will see a prompt with connection information.
   Look for an IP address like     `192.168.179.xxx`.
   This is your device’s IP.

3. On your PC, open a terminal and run:

   ```
   ssh -p 2222 root@<IP_FROM_ABOVE>
   ```
   
4. Run:

   ```sh
   ls /etc/ | grep dhcp
   ```
   
   If it returns `udhcpd.conf` then jump to the **udhcpc** section if it is `dhcpcd.conf` then follow the instructions in the **DHCP** section
   
#### DHCP

1. Edit the DHCP config file:

   ```
   vi /etc/dhcpcd.conf
   ```

   At the bottom, you should already see:

   ```
   nohook lookup-hostname
   ```

  2. Press **i** to enter insert mode and change it to:

   ```
   nohook lookup-hostname, resolv.conf
   ```

3. Press **ESC**, then type:

   ```
   :wq
   ```

   and press Enter.

4. Now edit the DNS resolver file:

   ```
   vi /etc/resolv.conf
   ```

   Change it to:

   ```
   nameserver 1.1.1.1
   ```

5. Press **ESC**, then type:

   ```
   :wq
   ```

   and press Enter.

  
#### udhcpc

1. Run

```sh
vi /usr/share/udhcpc/default.script
```

2. Enter insert mode by pressing `i` on your keyboard

3. Add the line `echo nameserver 1.1.1.1 >> $RESOLV_CONF` above `echo -n > $RESOLV_CONF`

4. Save and Quit with `ESC` and then `:wq`

5. Finally, if you want this change to be permanent, you'll need to run this command:

 `mntroot rw` 
 This will set your filesystem to writable.

#### Finishing up

To make these changes more persistent, you can set the files you touched to be immutable, even to `root`,
which should help prevent future updates from overwriting your changes. Simply run `chattr +i` on the files
you modified. To undo these changes later, run `chattr -i` against the same files.

**For udhcpc**:
 
• `chattr +i /usr/share/udhcpc/default.script` 

**For dhcp**:
• `chattr +i /etc/resolv.conf`
and
`chattr +i /etc/dhcpcd.conf`

- Reboot your device and try again.

## Keywords

KOReader, Anna's Archive, e-reader, plugin, ebook, download, KOReader plugin, digital library, e-ink, reading, open source.
