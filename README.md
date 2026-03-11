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
4. Enter a query, then optionally adjust sort order, languages, formats, download directory, or timeout settings.
5. Open a search result.
6. Tap the format line to download the file.

Notes:

- There is no account setup step.
- There is no `annas_credentials.lua` override file anymore.
- Recommended and most-popular Z-library-era browsing paths were removed because Anna's Archive does not use that API flow in this plugin.

## DNS Settings

**On some devices, you may need to change your DNS provider to 1.1.1.1 (Cloudflare).**

You only need to do this if Anna’s Archive repeatedly does not work, for example:

* Downloads not working
* No results found (even when searching for something general)
* “All protocols failed” errors

### Router-first fix

If you control your router, prefer changing DNS there instead of modifying files on the reader. Search for:

> **Change DNS to 1.1.1.1 on {Your Router Model}**

and follow the instructions for your hardware.

### Device-level fix (Kobo & Kindle)

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

To make these changes 'permanent' you can set the files you touched to be immutable, even to `root`, 
which should prevent future updates from overwriting your changes. Simply run `chattr +` to the files
you modified. To undo these changes later simply run `chattr -i` against the same files. 

**For udhcpc**:
 
• `chattr +i /usr/share/udhcpc/default.script` 

**For dhcp**:
• `chattr +i /etc/resolv.conf`
and
`chattr +i /etc/dhcpcd.conf`

- Reboot your device and try again.

  Done!

## Keywords

KOReader, Anna's Archive, e-reader, plugin, ebook, download, KOReader plugin, digital library, e-ink, reading, open source.
