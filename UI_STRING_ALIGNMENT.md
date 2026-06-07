# ui.qvm string-table compatibility with retail data

The Android UI module is rebuilt from the Elite Force GDK (`Code-DM/ui`) sources, which
are older than the retail game's final string tables. This note records why the rebuilt
`ui.qvm` is nevertheless string-compatible with retail `pak2.pk3` — verified by
structural alignment, not assumption.

## Parser semantics

`UI_ParseMenuText` / `UI_ParseButtonText` (`ui_atoms.c`) fill their tables starting at
index 1 (index 0 is `MNT_NONE`/`MBT_NONE`). So enum value V maps to the V-th quoted
token in the `.dat` file, 1-based. `MBT` entries are pairs (label, description); the
parser reads both per entry.

## Alignment result (GDK enums vs retail pak2 `ext_data/*.dat`)

- `MNT` / `mp_normaltext.dat`: enum values 1–418 align exactly with retail tokens
  1–418. The only divergence is 18 retail tokens appended at 419+ (SP/expansion class
  and parameter strings) — beyond `MNT_MAX`, unused. No mid-stream shifts.
- `MBT` / `mp_buttontext.dat`: enum values 1–255 align exactly with retail tokens
  1–255. The only divergence is 10 retail tokens appended at 256+ — beyond `MBT_MAX`,
  unused. No mid-stream shifts.

Many enum *names* differ from the retail *strings* (e.g. `MNT_BABYLEVEL` → "CADET",
`MNT_DEMOS` → "DEMONSTRATIONS"). These are renames of the same slot, not structural
shifts; the displayed retail string is the correct one.

## Conclusion

No enum edits and no custom `.dat` files are needed. The rebuilt `ui.qvm` shows all
strings correctly with the unmodified retail pak2 `.dat` files.

The corollary: never ship a `.dat` from a different source next to the rebuilt qvm. An
earlier build shipped a loose `mp_normaltext.dat` that did not match retail and every
menu string shifted. Ship only the qvm and let pak2 provide the string data.
