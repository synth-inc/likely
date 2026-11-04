Files here are copied into Likely.app/Contents/Resources by build.sh.

- `likely-demo.mp4`: the onboarding welcome-page demo video (shown at 434pt wide, 16:10). Until it exists, the page shows a "Demo video coming soon" placeholder.
- `AppIcon.icns`: the app icon ("Gentle Question"), referenced by `CFBundleIconFile` in Info.plist.
- `MenuBarGlyph.pdf`: the menu bar icon, a black-on-transparent template drawn at 18pt (currently layout 04 "knockout" from the icon editor). Replace this one file to change it.
- `SearchMark.png` / `SearchMark@2x.png`: Likely's mark on the left of the bar above the picker (20pt).

`../ResourcesDev/MenuBarGlyphs/` holds candidate menu bar glyphs; only dev builds (`./build.sh`) bundle them, for Settings → Debug.
