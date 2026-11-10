# PCB project — working rules for Claude Code

Copy this file into the root of a KiCad project and fill in the TODOs.

## Project
- Device: TODO (one paragraph: what it does, power source, interfaces)
- Board: TODO layers, TODO × TODO mm, 1.6 mm FR-4, HASL/ENIG
- Fab + assembly: JLCPCB (standard process). Prefer JLC *basic* parts; every part needs an `LCSC` field.

## Toolchain (all headless)
- KiCad 9: `kicad-cli`, Python API via `eda-python` (has `pcbnew`, `kikit`, `build123d`).
- Schematic and board files are plain S-expressions; edit them with scripts or
  `pcbnew`, never by hand-guessing coordinates.
- Datasheets live in `docs/datasheets/`. Read the relevant one before choosing
  pins, passives or a reference circuit, and cite the page in a comment.

## The loop — after EVERY schematic or layout change
1. `pcb-check` (add `--render` when placement changed).
2. Read `out/check/erc.json` / `drc.json` and look at the PNGs in `out/check/`.
3. Fix errors. Warnings you deliberately accept go in `docs/waivers.md` with a reason.
4. Do not report a step as done while `pcb-check` exits non-zero.

## Layout rules
- Place by function: decoupling caps within 2 mm of their pin, crystals next to
  the MCU, connectors on the board edge in the orientation the enclosure needs.
- Route critical nets first: USB/MIPI diff pairs (90 Ω), power, clocks, then the rest.
- Keep the ground plane unbroken under high-speed signals; no vias in diff pairs
  unless both legs get one.
- If routing is stuck, rip up and re-place rather than piling on vias.
- JLC limits (2/4-layer standard): 0.127 mm track/space, 0.3 mm drill, 0.45 mm via pad.
  Keep these in the project's DRC settings, not just here.

## Outputs
- `pcb-check --fab` → `out/fab/` (gerbers, BOM, CPL). Only when DRC is clean.
- Enclosure scripts in `mech/`, built with `eda-python`; check board-to-case
  clearance against the board STEP (`kicad-cli pcb export step`).
- Commit after each passing `pcb-check` with a message saying what changed.
