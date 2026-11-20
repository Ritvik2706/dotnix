// glass_cursor.glsl — dotnix cursor trail, in step with the wallpaper theme.
//
// When the cursor JUMPS (more than a couple of cells, or to another line) a
// short tapered comet streaks from the old spot to the new one and the cursor
// lands with a soft halo. Plain typing (1-2 cell moves) draws nothing.
//
// Colours are not hard-coded: the head is the cursor colour and the tail is
// ANSI magenta, both written by theme/wallpaper-theme.py (ghostty/wall-colours),
// so the trail re-themes with every wallpaper (Mod+P).
//
// Cost: after ~0.35 s the shader is a single texture fetch.

const float TRAIL_TIME = 0.20;  // s, tail catching up to the head
const float GLOW_TIME  = 0.38;  // s, landing halo fade
const float TRAIL_ALPHA = 0.55; // peak trail opacity (glass: text stays readable)
const float GLOW_ALPHA  = 0.22; // peak halo opacity
const float MIN_JUMP_CELLS = 2.5; // same-line moves shorter than this are ignored

float easeOutCubic(float x) { float i = 1.0 - x; return 1.0 - i * i * i; }

// Rounded box SDF (centre c, half size b, radius r)
float sdRoundBox(vec2 p, vec2 c, vec2 b, float r) {
    vec2 q = abs(p - c) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Tapered capsule from a (radius ra) to b (radius rb); returns (sdf, h along a->b)
vec2 sdTaper(vec2 p, vec2 a, vec2 b, float ra, float rb) {
    vec2 ba = b - a;
    float h = clamp(dot(p - a, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return vec2(length(p - a - ba * h) - mix(ra, rb, h), h);
}

vec3 screenBlend(vec3 base, vec3 c, float a) {
    return 1.0 - (1.0 - base) * (1.0 - c * a);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = texture(iChannel0, uv);

    float t = iTime - iTimeCursorChange;
    if (t > GLOW_TIME || iFocus == 0 || iCursorVisible.x < 0.5) return;

    // Cursor rects: xy = top-left corner (y up), zw = size, in pixels.
    vec2 curC  = iCurrentCursor.xy  + vec2(iCurrentCursor.z,  -iCurrentCursor.w)  * 0.5;
    vec2 prevC = iPreviousCursor.xy + vec2(iPreviousCursor.z, -iPreviousCursor.w) * 0.5;
    float cellH = max(iCurrentCursor.w, 1.0);
    float cellW = cellH * 0.5; // bar/underline cursors are thin; use the cell shape

    vec2 d = curC - prevC;
    bool sameLine = abs(d.y) < cellH * 0.5;
    if (sameLine && abs(d.x) < cellW * MIN_JUMP_CELLS) return;
    // A previous cursor of zero size (first frame, new surface) is not a jump.
    if (iPreviousCursor.w < 1.0) return;

    vec3 head = iCurrentCursorColor.rgb;
    vec3 tail = iPalette[5];
    vec3 col = fragColor.rgb;

    // Keep the cursor cell itself crisp: Ghostty already drew it.
    float inCursor = sdRoundBox(fragCoord, curC, iCurrentCursor.zw * 0.5, 0.0);

    // --- comet: head sits on the cursor, tail eases from prev to cur ---
    float tt = clamp(t / TRAIL_TIME, 0.0, 1.0);
    if (tt < 1.0) {
        vec2 tailP = mix(prevC, curC, easeOutCubic(tt));
        float rHead = cellH * 0.30;
        float rTail = cellH * 0.04;
        vec2 s = sdTaper(fragCoord, curC, tailP, rHead, rTail);
        float edge = 1.0 - smoothstep(-1.0, 1.0, s.x);
        // fade toward the tail and overall as it collapses
        float a = edge * (1.0 - s.y) * (1.0 - tt * tt) * TRAIL_ALPHA;
        vec3 c = mix(head, tail, s.y);
        col = screenBlend(col, c, a * step(0.0, inCursor));
    }

    // --- landing halo: soft rounded glow around the cursor cell ---
    float g = clamp(t / GLOW_TIME, 0.0, 1.0);
    float halo = sdRoundBox(fragCoord, curC, vec2(cellW, cellH) * 0.5, cellH * 0.25);
    float spread = cellH * mix(0.35, 0.9, easeOutCubic(g));
    float ga = exp(-max(halo, 0.0) / spread * 2.2) * (1.0 - g) * (1.0 - g) * GLOW_ALPHA;
    col = screenBlend(col, head, ga * step(0.0, inCursor));

    fragColor.rgb = col;
}
