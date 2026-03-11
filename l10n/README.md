# [KOReader Annas Plugin](https://github.com/fischer-hub/annas.koplugin)

## Localization Files

This directory contains localization and translation files for the plugin.

### File Structure
```
l10n/
├── {language_code}/      # Translation directory (e.g. 'fr', 'zh_CN', 'es')
│   └── koreader.po       # translation file
└── koreader.pot          # Translation template
```

## How to Translations
1. **Locate PO Files**
   - Navigate to the plugin's `l10n` directory:
     ```
    koreader/plugins/annas.koplugin/l10n/{language_code}/koreader.po
     ```
   - Example (Japanese):
     ```
    annas.koplugin/l10n/ja/koreader.po
     ```

2. **Add New Language**
   - If your language is not supported:
     1. Create a folder named with [ISO 639-1 language code](https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes) (e.g. `zh_CN` for Chinese, `fr` for French)
     2. Copy the template file `l10n/koreader.pot` to the new folder
     3. Rename it to `koreader.po` and edit the translation content

3. **Edit PO Files**
  - Use a text editor or tools like [Poedit](https://poedit.net/) to translate `msgstr` fields. Do not modify `msgid` values manually.
  - Update from `l10n/koreader.pot` when strings change in the live Anna plugin.
  - You can submit translations via pull request.

## Notes
- The plugin automatically loads translations based on the KOReader language.
- Missing or outdated translations fall back to English.