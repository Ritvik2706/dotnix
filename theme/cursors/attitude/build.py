#!/usr/bin/env python3
"""Render Bibata Ice Attitude's editable SVGs into animated Xcursor files."""
import io
import json
from pathlib import Path
import re
import struct
import subprocess

from PIL import Image

ROOT = Path(__file__).resolve().parent
THEME = ROOT.parent / 'Bibata-Modern-Ice-Attitude'
SIZES = (16, 20, 21, 22, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96)
TYPE = 0xFFFD0002
ART = ROOT / 'svg'
STYLE = 'fill="white" stroke="black" stroke-width="17" stroke-linejoin="round" stroke-linecap="round"'


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">{body}</svg>'


def base(name):
    source = (ROOT / 'base' / f'{name}.svg').read_text()
    return re.sub(r'^.*?<svg[^>]*>|</svg>\s*$', '', source, flags=re.S).replace('#00FF00', '#FFFFFF').replace('#0000FF', '#000000')


def path(d, width=17):
    return f'<path d="{d}" {STYLE.replace("17", str(width))}/>'


def line(d, width=12):
    return f'<path d="{d}" fill="none" stroke="black" stroke-width="{width}" stroke-linecap="round"/>'


def assets():
    result = {}
    def add(name, bodies, hot=(128, 128), delay=100):
        if isinstance(bodies, str):
            bodies = [bodies]
        result[name] = ([svg(b) for b in bodies], hot, delay)

    # Carve a bite into the original arrow's left edge, away from its tip.
    arrow = base('left_ptr').replace('L45.4999 200.431', 'L45.4999 102C72 100 76 129 45.4999 136L45.4999 200.431')
    add('left_ptr', arrow, (57, 17))
    add('right_ptr', f'<g transform="translate(256 0) scale(-1 1)">{arrow}</g>', (199, 17))
    add('hand2', base('hand2'), (145, 17))
    add('hand1', base('hand1') + line('M111 91L117 128M151 81L150 122M186 91L177 130', 9))
    # Thumb peeks between the folded fingers, behind the original fist.
    thumb = path('M112 84L108 48Q107 29 123 29Q139 29 141 47L145 82Z')
    add('grabbing', thumb + base('grabbing') + line('M104 99L111 126M139 91L143 120M175 101L175 125', 9))

    frames = []
    # Three rounded fingertips drum in sequence; the palm and hotspot stay put.
    for lift in (0, 1, 2, 3, 2, 1):
        fingers = ''
        for i, x in enumerate((76, 126, 176)):
            bottom = 218 - (25 if lift == i + 1 else 0)
            fingers += path(f'M{x} 108V{bottom-19}Q{x} {bottom} {x+19} {bottom}Q{x+38} {bottom} {x+38} {bottom-19}V108Z')
        palm = path('M76 36H156V64H177Q214 64 214 104V139H76L58 165Q45 183 30 173Q18 163 28 146L49 106V89Q49 68 76 64Z')
        frames.append(fingers + palm)
    add('wait', frames, (128, 106), 125)

    frames = []
    for lift in (0, 5, 13, 5, 0, 0):
        foot = path(f'M150 155L154 {208-lift}L192 {208-lift}Q213 {208-lift} 215 {224-lift}H138Q128 {224-lift} 128 {213-lift}V155Z')
        frames.append(foot + f'<g transform="translate(0 4) scale(.76)">{arrow}</g>')
    add('left_ptr_watch', frames, (43, 17), 110)

    pinch = path('M119 232L109 193Q77 177 58 147L37 107Q28 90 43 78L68 57Q92 37 116 57L153 94Q165 75 181 87Q191 94 190 109Q205 99 216 114Q225 128 217 149L210 189L198 232Z')
    pinch += line('M43 78Q55 70 70 84L107 117Q93 121 79 111L60 96M58 147Q82 151 107 117M153 94L170 124M190 109L194 133', 12)
    for name in ('crossed_circle', 'circle', 'dnd_no_drop'):
        add(name, pinch, (39, 93))

    # The top and bottom of a conventional I-beam become two small jaws.
    teeth = path('M78 27H178V69L157 55L140 70V186L157 201L178 187V229H78V187L99 201L116 186V70L99 55L78 69Z', 14)
    add('xterm', teeth)
    add('vertical-text', f'<g transform="rotate(90 128 128)">{teeth}</g>')

    gum = path('M23 128L68 83Q76 76 76 90V105Q128 124 180 105V90Q180 76 188 83L233 128L188 173Q180 180 180 166V151Q128 132 76 151V166Q76 180 68 173Z', 15)
    for name, angle in (('sb_h_double_arrow', 0), ('sb_v_double_arrow', 90), ('bd_double_arrow', 45), ('fd_double_arrow', -45)):
        add(name, f'<g transform="rotate({angle} 128 128)">{gum}</g>')
    # Use matching double arrows for edge/corner resize roles too.
    for name, source in {
        'left_side':'sb_h_double_arrow', 'right_side':'sb_h_double_arrow',
        'top_side':'sb_v_double_arrow', 'bottom_side':'sb_v_double_arrow',
        'top_left_corner':'bd_double_arrow', 'bottom_right_corner':'bd_double_arrow',
        'top_right_corner':'fd_double_arrow', 'bottom_left_corner':'fd_double_arrow',
    }.items():
        result[name] = result[source]

    move = path('M128 20L158 54H143V88Q167 89 168 113H202V98L236 128L202 158V143H169Q168 167 143 168V202H158L128 236L98 202H113V168Q87 167 87 143H54V158L20 128L54 98V113H87Q88 89 113 88V54H98Z', 14)
    # Soft asymmetric edges make the center feel slightly squished.
    move += line('M108 109Q119 100 138 106', 8)
    add('move', move)

    question = base('question_arrow')
    question += line('M59 122Q74 109 91 115', 13)
    add('question_arrow', question)

    cross = ''
    for angle in (0, 90, 180, 270):
        cross += f'<g transform="rotate({angle} 128 128)">{path("M119 27H137V69H119Z", 12)}</g>'
    cross += '<ellipse cx="113" cy="117" rx="16" ry="11" fill="white" stroke="black" stroke-width="9" transform="rotate(35 113 117)"/>'
    cross += '<ellipse cx="143" cy="117" rx="16" ry="11" fill="white" stroke="black" stroke-width="9" transform="rotate(-35 143 117)"/>'
    cross += '<ellipse cx="128" cy="134" rx="10" ry="18" fill="black"/>'
    for name in ('crosshair', 'cross', 'tcross'):
        add(name, cross)
    return result


def compile_cursor(frames, hot, delay):
    chunks, entries = [], []
    for size in SIZES:
        for frame in frames:
            png = subprocess.check_output(['rsvg-convert', '-w', str(size*4), '-h', str(size*4)], input=frame.encode())
            image = Image.open(io.BytesIO(png)).convert('RGBA').resize((size, size), Image.Resampling.LANCZOS)
            pixels = bytearray()
            for r,g,b,a in struct.iter_unpack('4B', image.tobytes()):
                pixels.extend((b*a//255, g*a//255, r*a//255, a))
            chunks.append(struct.pack('<9I',36,TYPE,size,1,size,size,round(hot[0]*size/256),round(hot[1]*size/256),delay)+pixels)
            entries.append(size)
    offset = 16+12*len(chunks)
    output = bytearray(struct.pack('<4I',0x72756358,16,0x10000,len(chunks)))
    for size,chunk in zip(entries,chunks):
        output.extend(struct.pack('<3I',TYPE,size,offset))
        offset += len(chunk)
    return output+b''.join(chunks)


def main():
    ART.mkdir(exist_ok=True)
    dest = THEME/'cursors'
    dest.mkdir(parents=True, exist_ok=True)
    (THEME/'index.theme').write_text('[Icon Theme]\nName=Bibata Ice Attitude\nComment=Bitten arrows, impatient hands and small acts of cursor rebellion\nInherits=Bibata-Modern-Ice\n')
    aliases = json.loads((ROOT/'aliases.json').read_text())
    collection = assets()
    manifest = {}
    for name,(frames,hot,delay) in collection.items():
        for i,frame in enumerate(frames):
            (ART/f'{name}-{i:02}.svg').write_text(frame+'\n')
        (dest/name).write_bytes(compile_cursor(frames,hot,delay))
        manifest[name] = dict(frames=len(frames),hotspot=hot,delay=delay,sizes=SIZES)
        for alias in aliases.get(name,[]):
            target = dest/alias
            if not target.is_symlink():
                target.symlink_to(name)
    (ROOT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    preview(collection)
    print(f'Built {len(collection)} cursor roles, {len(list(dest.iterdir()))} names, {len(SIZES)} sizes.')


def preview(collection):
    names = ['left_ptr','hand2','hand1','grabbing','wait','left_ptr_watch','crossed_circle','xterm','sb_h_double_arrow','move','question_arrow','crosshair']
    labels = ['Bitten arrow','Signature link','Ready to grab','Cheeky fist','Impatient fingers','Tapping foot','Nothing for you','Text teeth','Chewing gum resize','Squishy move','Skeptical help','Fly crosshair']
    body = '<rect width="1040" height="850" fill="#c8cbd0"/>'
    for i,(name,label) in enumerate(zip(names,labels)):
        x,y = 20+(i%4)*255,20+(i//4)*275
        frame = collection[name][0][0]
        inner = re.sub(r'^<svg[^>]*>|</svg>$','',frame)
        body += f'<rect x="{x}" y="{y}" width="240" height="260" rx="18" fill="#eceef1"/>'
        body += f'<g transform="translate({x+47} {y+10}) scale(.57)">{inner}</g>'
        body += f'<g transform="translate({x+109} {y+175}) scale({21/256})">{inner}</g>'
        body += f'<text x="{x+120}" y="{y+234}" text-anchor="middle" font-family="sans-serif" font-size="16" fill="#25272a">{label}</text>'
    (ROOT/'preview.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1040" height="850" viewBox="0 0 1040 850">{body}</svg>')
    subprocess.run(['rsvg-convert',str(ROOT/'preview.svg'),'-o',str(ROOT/'preview.png')],check=True)
    animation_data = {name: {'frames': collection[name][0], 'delay': collection[name][2]}
                      for name in ('wait', 'left_ptr_watch')}
    (ROOT/'preview.html').write_text('''<!doctype html><meta charset="utf-8">
<title>Bibata Ice Attitude preview</title>
<style>body{background:#c8cbd0;color:#25272a;font:16px system-ui;max-width:1040px;margin:30px auto}img{max-width:100%}.animations{display:flex;gap:24px}.card{background:#eceef1;border-radius:18px;padding:24px;text-align:center}.art svg{width:128px;height:128px}.actual svg{width:21px;height:21px}</style>
<h1>Bibata Ice Attitude</h1><p>Enlarged designs and native 21-pixel samples.</p>
<img src="preview.png" alt="Twelve customized Bibata cursor designs">
<div class="animations"><div class="card"><p>Impatient fingers</p><div class="art" id="wait"></div><div class="actual" id="wait-small"></div></div><div class="card"><p>Tapping foot</p><div class="art" id="left_ptr_watch"></div><div class="actual" id="left_ptr_watch-small"></div></div></div>
<script>const animations = '''+json.dumps(animation_data)+''';
for (const [name, animation] of Object.entries(animations)) {
 let i=0; const show=()=>{for(const suffix of ['', '-small']) document.getElementById(name+suffix).innerHTML=animation.frames[i]; i=(i+1)%animation.frames.length};
 show(); setInterval(show, animation.delay);
}</script>''')


if __name__ == '__main__':
    main()
