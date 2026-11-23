"""Generates the SideCast app icon SVG sources (concept E: a music note flying from a Mac to an iPad).

Variants:
  icon-light.svg  full-bleed square with background (iOS default, macOS base art)
  icon-dark.svg   foreground only on transparent background (iOS dark appearance)
"""

def foreground(dark=False, parts=("devices", "note"), transform="translate(28 50)", details=True):
    lid = "#D4D0F7" if not dark else "#B9B3F0"
    screen_top, screen_bottom = ("#4C42B0", "#2B2479") if not dark else ("#3A318F", "#1E1959")
    tablet = "#FFFFFF" if not dark else "#ECEAFB"
    tablet_screen = "#E6E3FC" if not dark else "#2E2780"
    play = "#5148B8" if not dark else "#9FE1CB"
    teal = "#5DCAA5"
    teal_light = "#9FE1CB"
    return f'''
  <g transform="{transform}">
  <defs>
    <linearGradient id="screen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{screen_top}"/><stop offset="1" stop-color="{screen_bottom}"/>
    </linearGradient>
    <linearGradient id="note" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{teal_light}"/><stop offset="1" stop-color="{teal}"/>
    </linearGradient>
  </defs>
  {"" if "devices" in parts else "<!--"}
  {"" if details else "<!--"}
  <path d="M318 448 C 352 214, 648 178, 768 344" fill="none" stroke="{teal}" stroke-width="22"
        stroke-linecap="round" stroke-dasharray="0.1 50" opacity="0.9"/>
  {"" if details else "-->"}
  <rect x="114" y="452" width="432" height="290" rx="34" fill="{lid}"/>
  <rect x="138" y="476" width="384" height="242" rx="14" fill="url(#screen)"/>
  {"" if details else "<!--"}
  <rect x="246" y="590" width="26" height="76" rx="13" fill="{teal}"/>
  <rect x="290" y="550" width="26" height="116" rx="13" fill="{teal_light}"/>
  <rect x="334" y="574" width="26" height="92" rx="13" fill="{teal}"/>
  <rect x="378" y="610" width="26" height="56" rx="13" fill="{teal_light}"/>
  {"" if details else "-->"}
  <path d="M70 742 H 590 a10 10 0 0 1 10 10 v 4 a 26 26 0 0 1 -26 26 H 86 a 26 26 0 0 1 -26 -26 v -4 a10 10 0 0 1 10 -10 Z" fill="{lid}"/>
  <rect x="276" y="742" width="108" height="14" rx="7" fill="{screen_bottom}" opacity="0.35"/>
  <rect x="632" y="376" width="276" height="406" rx="46" fill="{tablet}"/>
  <rect x="656" y="400" width="228" height="358" rx="26" fill="{tablet_screen}"/>
  <path d="M740 524 L 740 640 a 10 10 0 0 0 15 8.7 L 846 595 a 10 10 0 0 0 0 -17.4 L 755 515 a 10 10 0 0 0 -15 8.7 Z" fill="{play}"/>
  {"" if "devices" in parts else "-->"}
  {"" if "note" in parts else "<!--"}
  <g transform="rotate(-12 500 230)">
    <ellipse cx="468" cy="286" rx="64" ry="50" transform="rotate(-22 468 286)" fill="url(#note)"/>
    <rect x="508" y="120" width="28" height="170" rx="10" fill="url(#note)"/>
    <path d="M522 120 C 600 128, 640 180, 618 252 C 606 214, 580 192, 536 186 Z" fill="url(#note)"/>
  </g>
  {"" if "note" in parts else "-->"}
  </g>
'''

def svg(body, background=True):
    bg = '''
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#4338A8"/><stop offset="1" stop-color="#1F1A4F"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.22" r="0.55">
      <stop offset="0" stop-color="#7F77DD" stop-opacity="0.45"/><stop offset="1" stop-color="#7F77DD" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>''' if background else ''
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{bg}{body}</svg>\n'

open("icon-light.svg", "w").write(svg(foreground(dark=False)))
# Small macOS sizes (16 and 32 px): no dots or bars, artwork enlarged.
small = "translate(512 540) scale(1.12) translate(-512 -512) translate(28 30)"
open("icon-small.svg", "w").write(svg(foreground(transform=small, details=False)))
# visionOS: circular icon, three layers; content scaled into the circle's safe area.
vision = "translate(512 512) scale(0.78) translate(-512 -512) translate(28 50)"
open("vision-back.svg", "w").write(svg("", background=True))
open("vision-middle.svg", "w").write(svg(foreground(parts=("devices",), transform=vision), background=False))
open("vision-front.svg", "w").write(svg(foreground(parts=("note",), transform=vision), background=False))
open("icon-dark.svg", "w").write(svg(foreground(dark=True), background=False))
print("ok")
