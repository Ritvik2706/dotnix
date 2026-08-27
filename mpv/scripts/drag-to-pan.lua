-- drag-to-pan.lua
-- Hold Ctrl and drag with the trackpad/mouse to pan a zoomed-in video.
-- Pairs with the Ctrl+scroll zoom binds in input.conf.

local mp = require 'mp'

local dragging = false
local last_x, last_y = 0, 0

local function osd_dims()
    local d = mp.get_property_native('osd-dimensions')
    if not d or d.w == 0 or d.h == 0 then return nil end
    return d.w, d.h
end

local function on_move()
    if not dragging then return end
    local x, y = mp.get_mouse_pos()
    local w, h = osd_dims()
    if not w then return end

    local dx = (x - last_x) / w
    local dy = (y - last_y) / h
    last_x, last_y = x, y

    mp.set_property_number('video-pan-x',
        mp.get_property_number('video-pan-x', 0) + dx)
    mp.set_property_number('video-pan-y',
        mp.get_property_number('video-pan-y', 0) + dy)
end

mp.add_forced_key_binding('Ctrl+MBTN_LEFT', 'drag-to-pan', function(e)
    if e.event == 'down' then
        dragging = true
        last_x, last_y = mp.get_mouse_pos()
        mp.observe_property('mouse-pos', 'native', on_move)
    elseif e.event == 'up' then
        dragging = false
        mp.unobserve_property(on_move)
    end
end, { complex = true })
