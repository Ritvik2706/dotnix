// The now-playing squiggle: what has played is a wave travelling towards an
// upright thumb, what is left a flat track; round caps everywhere.
//   s.a.x  how far into the song, 0..1
//   s.a.y  the wave's height in px (0 lays it flat: it rises as a song starts)
//   s.a.z  the track's opacity
//   s.a.w  the wavelength in px (0: 10)
//   s.color   the wave and the thumb    s.color2  the track

fn cover(d: f32, half: f32, scale: f32) -> f32 {
    return clamp((half - d) * scale + 0.5, 0.0, 1.0);
}

fn shade(s: Shader) -> vec4<f32> {
    let w = s.size.x;
    let cy = s.size.y * 0.5;
    let m = 1.5;                       // room for the round caps
    let px = m + (w - 2.0 * m) * clamp(s.a.x, 0.0, 1.0);
    let gap = 3.5;                     // clear space either side of the thumb
    let half = 1.0;                    // half the stroke
    let k = 6.2831853 / select(10.0, s.a.w, s.a.w > 0.0);
    let ph = s.time * 4.2;             // drifting towards the thumb

    // The wave, from the start to just short of the thumb, flattening into
    // it so it meets the thumb at its middle.
    var a_wave = 0.0;
    let end = px - gap;
    if (end > m) {
        let xc = clamp(s.pos.x, m, end);
        let taper = clamp((end - xc) / 6.0, 0.0, 1.0) * clamp((xc - m) / 3.0, 0.0, 1.0);
        let amp = s.a.y * taper;
        let f = cy + amp * sin(k * xc - ph);
        let df = amp * k * cos(k * xc - ph);
        let dx = s.pos.x - xc;
        let dy = (s.pos.y - f) / sqrt(1.0 + df * df);
        a_wave = cover(length(vec2<f32>(dx, dy)), half, s.scale);
    }

    // The track: flat, from just past the thumb to the end.
    var a_track = 0.0;
    let start = px + gap;
    if (start < w - m) {
        let xc = clamp(s.pos.x, start, w - m);
        a_track = cover(length(vec2<f32>(s.pos.x - xc, s.pos.y - cy)), half, s.scale) * s.a.z;
    }

    // The thumb: an upright capsule.
    let th = 6.0;
    let dyt = max(abs(s.pos.y - cy) - (th - 1.2), 0.0);
    let a_thumb = cover(length(vec2<f32>(s.pos.x - px, dyt)), 1.2, s.scale);

    let a_lit = max(a_wave, a_thumb);
    let a_dim = a_track * (1.0 - a_lit);
    let a = a_lit + a_dim;
    let rgb = (s.color.rgb * a_lit + s.color2.rgb * a_dim) / max(a, 0.0001);
    return vec4<f32>(rgb, a);
}
