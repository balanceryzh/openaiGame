# Asset sources and redistribution status

- `assets/interface.ttf`: embedded font metadata identifies **Noto Sans CJK SC Regular**, copyright 2014–2021 Adobe, SIL Open Font License 1.1. This project uses a subset. The complete distribution copyright/license notice is included at `licenses/Noto-CJK-copyright.txt`.
- Character and environmental raster artwork: existing project-generated assets. Local authoring provenance identifies image-generation outputs for terrain/vegetation and generated/redrawn character frames; no claim of exclusively human-authored pixel art. The accepted 36 walking images are preserved byte-for-byte, with per-file SHA-256 and anchors in `assets/approved_walk12/manifest.json`.
- `audio_v2/`: existing game sound effects. Local bow revision notes identify the bow layers as original synthesized variants. Other effect files are preserved from the project; an independent asset-by-asset rights audit has not been performed.
- `audio_bgm/track_a.ogg` and `track_b.ogg`: identified by the existing project README as user-provided music. No separate redistribution license or ownership evidence was found in the project. These files remain staged locally for a complete runnable project. Confirm permission and intended repository visibility before making them publicly available.
- No blanket MIT, CC0, or other project license has been assigned. This source record is not a warranty of rights. Godot itself is a separate dependency and no engine binary is included.

Only this game directory is prepared for synchronization; caches, recorded videos, archives, credentials, unrelated projects, private conversation IDs and temporary capture scripts are excluded.
