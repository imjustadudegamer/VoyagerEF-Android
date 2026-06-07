# EF ui.qvm string-data alignment — verified

## Parser semantics
UI_ParseMenuText/UI_ParseButtonText (ui_atoms.c) use `i = 1` base (index 0 = MNT_NONE/MBT_NONE = null).
So enum value V -> menu_*_text[V] = the V-th quoted token in the .dat (1-based). MBT entries are pairs
(label, description); the parser reads both per entry.

## Result of difflib structural alignment (GDK Code-DM enums vs retail pak2 ext_data/*.dat)
- MNT / mp_normaltext.dat: enum values 1..418 align EXACTLY with retail tokens 1..418.
  Only structural divergence = 18 retail tokens APPENDED at value 419+ (SP/expansion class & param
  strings: "No Class","Infiltrator","Sniper",...,"V.I.P."). These are beyond MNT_MAX -> UNUSED. 0 mid-stream.
- MBT / mp_buttontext.dat: enum values 1..255 align EXACTLY with retail tokens 1..255.
  Only structural divergence = 10 retail tokens APPENDED at value 256+ ("ASSIMILATION","SPECIALTIES",
  "DISINTEGRATION","ACTION HERO","ELIMINATION","CLASS",...). Beyond MBT_MAX -> UNUSED. 0 mid-stream.

## Conclusion
NO enum edits and NO custom .dat are needed. A ui.qvm rebuilt from stvoy/Code-DM/ui will show all
strings correctly using the retail pak2 ext_data .dat. (Many enum NAMES differ from the retail STRINGS
— e.g. MNT_BABYLEVEL->"CADET", MNT_BOT->"HC", MNT_DEMOS->"DEMONSTRATIONS" — these are EF reskins of the
same SLOT; the displayed retail string is correct. They are 'replace' ops, not structural shifts.)

## Prior rebuild bug (root cause)
The earlier rebuild shipped a LOOSE ext_data/mp_normaltext.dat that did NOT match -> misalignment.
Fix: ship ONLY the rebuilt ui.qvm loose and let pak2 provide the .dat (verified aligned), OR ship the
exact pak2 .dat. Do not ship a different-version .dat.
