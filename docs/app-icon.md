# App icon (Dock / Finder) — design spec

Shape / ship rules: [macos-app-icon skill](~/.agents/skills/macos-app-icon/SKILL.md) (and Fred’s shape table in `EggplantFred/docs/app-icon.md`).

## What we ship

| Rule | Value |
|------|--------|
| Master / generator | `build/AppIcon-1024-master.png` via `scripts/generate_app_icon.py` |
| Wails input | `build/appicon.png` → `build/darwin/icons.icns` |
| Shape | Continuous rounded rect, corner radius ≈ **22.37%** of edge; transparent corners |
| Art | **Near-black** field, light monitor, red REC disc |
| Bundle | Classic only: `CFBundleIconFile=icons`, **no** `CFBundleIconName`, **no** `Assets.car` |

Do **not** copy EggplantFred’s purple field — that is Fred artwork, not a family rule.

```bash
python3 scripts/generate_app_icon.py
rm -rf bin/EggplantRecorder.app
wails3 package
# sticky Dock tile: lsregister -f bin/EggplantRecorder.app && killall Dock
```
