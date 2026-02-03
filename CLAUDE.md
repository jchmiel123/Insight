# Insight Display System

HDMI overlay system for Tang Nano 20K FPGA. Workplace digital signage with watermarks, screensavers, and scheduled content.

**GitHub:** https://github.com/jchmiel123/Insight

## BEFORE YOU CODE - Check These First!

```bash
# Search ForgeRepo for existing patterns
python D:/CodeLab/ForgeRepo/capabilities_registry.py --search "your topic"

# After you build something reusable, ADD IT:
python D:/CodeLab/ForgeRepo/capabilities_registry.py --add

# When something works well, VOTE IT UP:
python D:/CodeLab/ForgeRepo/capabilities_registry.py --vote "Name" --note "why it's good"

# When you learn a gotcha, RECORD IT:
python D:/CodeLab/ForgeRepo/capabilities_registry.py --learn "Name" --note "the gotcha"
```

## Quick Start

```bash
# Open in Gowin EDA IDE
# File -> Open Project -> insight.gprj

# Or command line build
gw_sh build.tcl

# Program via openFPGALoader
openFPGALoader -b tangnano20k impl/pnr/insight.fs
```

## Project Structure

```
Insight/
├── src/
│   ├── insight_top.v       # Main top module
│   ├── insight.cst         # Pin constraints
│   ├── lib/
│   │   ├── video_timing.v  # 720p timing generator
│   │   ├── mode_controller.v # Button/IR input
│   │   └── watermark_overlay.v # Logo/text overlay
│   ├── modes/
│   │   ├── slots_screensaver.v # Slot machine fun
│   │   └── info_screen.v   # Test patterns, info display
│   └── ip/
│       ├── dvi_tx/         # Gowin DVI transmitter IP
│       └── gowin_rpll/     # PLL for TMDS clock
├── impl/                   # Build output
├── docs/
├── build.tcl               # TCL build script
└── insight.gprj            # Gowin IDE project
```

## Display Modes

Press S2 button to cycle through modes:

| Mode | Name | Description |
|------|------|-------------|
| 0 | Passthrough | Future HDMI input passthrough |
| 1 | Watermark | Show watermark overlay (default) |
| 2 | Fullscreen | Color bars test pattern |
| 3 | Slots | Slot machine screensaver |
| 4 | Info | Info display with boxes |
| 5 | Off | Blank screen |

## LED Indicators

- LED[2:0]: Current mode (binary)
- LED[3]: PLL lock status
- LED[4]: Heartbeat (~1Hz)
- LED[5]: Display enable activity

## Hardware

**Tang Nano 20K**
- Gowin GW2AR-18C FPGA
- 20K LUTs, 828KB Block SRAM
- 27MHz crystal
- HDMI output (DVI-compatible)
- 2 buttons, 6 LEDs

**Video Output**
- 1280x720 @ 60Hz (720p)
- 74.25 MHz pixel clock
- DVI/HDMI TMDS encoding

## Future Enhancements

- [ ] HDMI input (second Tang Nano 20K)
- [ ] SD card for images/video
- [ ] IR remote control
- [ ] RTC time display
- [ ] Scheduler for content rotation
- [ ] Font ROM for real text rendering
- [ ] Network control (ESP32 companion)

## Related Projects

- TangForge (D:\CodeLab\TangForge) - FPGA development base
- CSlots (slot machine games)

## Session Checklist

**Start of session:**
```bash
python D:/CodeLab/ForgeRepo/scripts/session_start.py
```

**End of session:**
```bash
git add -A && git commit -m "description" && git push
python D:/CodeLab/ForgeRepo/scripts/session_end.py
python D:/CodeLab/ForgeControl/tools/git_sync_reminder.py
```

**If you built something reusable:** Add it to ForgeRepo!
**If something worked great:** Vote it up!
**If you hit a gotcha:** Record the learning!
