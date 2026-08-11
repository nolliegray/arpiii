-- arpiii v1.3.0
pset_init("arpiii")

local ins, rem, sort = table.insert, table.remove, table.sort
local max, min, flr, ceil, rnd = math.max, math.min, math.floor, math.ceil, math.random

local log_keys, phys_keys, press_ord, arp_notes = {}, {}, {}, {}
local step, act_note, act_note_ch, last_note, last_gate = 1, nil, 1, nil, 0
local latch, oct_shift, oct_dn_h, oct_up_h = 0, 0, false, false
local midi_out, midi_in, midi_focus = 1, 0, 2
local act_octs, act_octs_ord = {[-2]=false, [-1]=false, [0]=true, [1]=false, [2]=false}, {0}
local playing, act_pg = false, 0
local bpm, clk_src, send_midi_clk, div_idx, mod_mode, swing = 120, 1, true, 5, 1, 50
local arp_speed, sys_t, ext_tick, taps = (60/bpm)/2, 0, 0, {}
local play_ords = {"ORDR", "LINE", "LEAP", "STAG", "SHFT", "SPRL", "ANCH", "ACCM", "WALK", "RAND"}
local cur_ord, mod_1, mod_2 = 1, false, false
local play_dir, rand_oct_idx, rand_cycle = 1, 1, 1

local pr_mode, presets, cur_pr = false, {}, nil
local p_h_n, p_h_t, p_svd, p_bl_n, p_bl_t = nil, 0, false, nil, 0
local play_h, play_h_t, play_svd, play_blink_t = false, 0, false, 0
local p_btns = {{3,1}, {5,2}, {4,3}, {15,5}, {7,6}}

local gate_seq, gate_vel, gate_gate, gate_held = {}, {}, {}, {}
local glb_vel, glb_gate, gate_len, gate_pos = 96, 50, 16, 0
for i=1,64 do gate_seq[i], gate_vel[i], gate_gate[i] = true, glb_vel, glb_gate end

local hist_buf, buf_held = {}, {}
for i=1,64 do hist_buf[i] = {n=nil, v=0, g=0, c=1} end
local buf_idx, buf_lock, buf_start, buf_end = 0, false, 1, 64
local edit_step, edit_h, edit_u = 1, false, false

local font = {
  [48]="011101101101110", [49]="010110010010111", [50]="110001111100111", [51]="110001111001111", [52]="101101111001001",
  [53]="111100111001110", [54]="011100111101111", [55]="111001010010010", [56]="011101111101110", [57]="111101111001110",
  [45]="000000111000000", [43]="000010111010000", [69]="111100110100111", [88]="101101010101101", [84]="111010010010010",
  [46]="000000000000010", [47]="001001010100100", [37]="101001010100101", [65]="011101111101101", [76]="100100100100111",
  [68]="110101101101110", [79]="011101101101110", [87]="101101101111101", [78]="110101101101101", [85]="101101101101011",
  [80]="011101111100100", [82]="011101110101101", [89]="101101111001110", [70]="111100111100100", [67]="011101100101110",
  [73]="111010010010111", [86]="101101101101010", [71]="011100101101111", [72]="101101111101101", [83]="011100010001110",
  [77]="101111101101101", [75]="101101110101101"
}
local br_map = {[0]=2, [1]=5, [2]=8, [3]=12, [4]=15} 
local div_strs = {{ "/1","/1T","/1."}, {"/2","/2T","/2."}, {"/4","/4T","/4."}, {"/8","/8T","/8."}, {"/16","/16T","/16."}, {"/32","/32T","/32."}, {"/64","/64T","/64."}}
local bpm_strs, swing_strs, ch_strs = {}, {}, {[-1]="OFF", [0]="ALL"}
for i=20,300 do bpm_strs[i]=tostring(i) end
for i=25,75 do swing_strs[i]=tostring(i).."%" end
for i=1,16 do ch_strs[i]=tostring(i) end

local key_map = {[8]={[3]=1,[4]=2,[5]=3,[6]=4,[7]=5,[8]=6,[9]=7,[10]=8,[11]=9,[12]=10,[13]=11,[14]=12,[15]=13,[16]=14}, [7]={[4]=15,[5]=16,[7]=17,[8]=18,[9]=19,[11]=20,[12]=21,[14]=22,[15]=23,[16]=24}}
local note_map = {[8]={[3]=48,[4]=50,[5]=52,[6]=53,[7]=55,[8]=57,[9]=59,[10]=60,[11]=62,[12]=64,[13]=65,[14]=67,[15]=69,[16]=71}, [7]={[4]=49,[5]=51,[7]=54,[8]=56,[9]=58,[11]=61,[12]=63,[14]=66,[15]=68,[16]=70}}
local note_xy = {}; for y, r in pairs(note_map) do for x, n in pairs(r) do note_xy[n] = {x=x, y=y} end end

local function norm_n(n) while n>127 do n=n-120 end; while n<0 do n=n+120 end; return n end
local grid_dirty = true
function redraw() grid_dirty = true end

local function draw_text(str, st_x, st_y)
  for c = 1, #str do
    local p = font[string.byte(str, c)]
    if p then for i=1,15 do if string.byte(p, i)==49 then grid_led(st_x+(c-1)*4+((i-1)%3), st_y+flr((i-1)/3), 5) end end end
  end
end

local function tx_midi(note, vel, ch, on)
  if ch == 0 then for c=1,16 do if on then midi_note_on(note,vel,c) else midi_note_off(note,vel,c) end end
  else if on then midi_note_on(note,vel,ch) else midi_note_off(note,vel,ch) end end
end

local function tx_midi_sys(d1)
  if _G.midi_tx then _G.midi_tx(d1) end
end

local function kill_act()
  if act_note then tx_midi(act_note, 0, act_note_ch, false); act_note = nil end
end

local function clear_log_keys()
  for n in pairs(log_keys) do tx_midi(n, 0, midi_out, false) end
  log_keys, press_ord = {}, {}
end

local function get_phys_ct() local c=0; for _ in pairs(phys_keys) do c=c+1 end; return c end

local function find_root_step()
  if #press_ord == 0 or #arp_notes == 0 then return 1 end
  local root = norm_n(press_ord[1] + ((act_octs[0] and 0 or 0) * 12))
  for i, n in ipairs(arp_notes) do
    if n == root or n % 12 == root % 12 then return i end
  end
  return 1
end

local function rebuild_arp()
  arp_notes = {}
  local octs, r_notes = {}, {}
  if act_octs[0] then ins(octs, 0) end
  for _, o in ipairs(act_octs_ord) do if o ~= 0 then ins(octs, o) end end
  
  if cur_ord == 9 then
    for _, oct in ipairs(octs) do
      for _, note in ipairs(press_ord) do ins(arp_notes, norm_n(note + (oct * 12))) end
    end
  else
    for _, oct in ipairs(octs) do
      for _, note in ipairs(press_ord) do ins(r_notes, norm_n(note + (oct * 12))) end
    end
  end

  local function get_srt(desc)
    local s={}; for _,v in ipairs(r_notes) do ins(s,v) end
    if desc then sort(s, function(a,b) return a>b end) else sort(s) end
    return s
  end

  if cur_ord == 1 then for _,v in ipairs(r_notes) do ins(arp_notes, v) end
  elseif cur_ord == 2 or cur_ord == 10 then 
    for _,v in ipairs(get_srt(false)) do ins(arp_notes, v) end
  elseif cur_ord == 3 then
    local s = get_srt(mod_1)
    if #s<=2 then for _,v in ipairs(s) do ins(arp_notes, v) end else
      local c, up = 1, true; ins(arp_notes, s[c])
      while true do c = up and (c+2) or (c-1); if c>#s then break end; ins(arp_notes, s[c]); up = not up end
    end
  elseif cur_ord == 4 or cur_ord == 5 then
    local s, sz = get_srt(mod_1), cur_ord == 4 and 3 or 4
    if #s < sz then for _,v in ipairs(s) do ins(arp_notes, v) end else
      for i=1, #s-(sz-1) do for j=0, sz-1 do ins(arp_notes, s[i+j]) end end
    end
  elseif cur_ord == 6 then
    local s = get_srt(false); local hi = (#s>0 and r_notes[1] >= (s[1]+s[#s])/2)
    local l, r = 1, #s
    while l<=r do
      if l==r then ins(arp_notes, s[l]) else ins(arp_notes, hi and s[r] or s[l]); ins(arp_notes, hi and s[l] or s[r]) end
      l, r = l+1, r-1
    end
  elseif cur_ord == 7 then
    local a, t = r_notes[1], {}; for i=2,#r_notes do ins(t, r_notes[i]) end; sort(t)
    if #t>0 then for _, v in ipairs(t) do ins(arp_notes, a); ins(arp_notes, v) end elseif a then ins(arp_notes, a) end
  elseif cur_ord == 8 then
    local function add_a(s) for i=1,#s do for j=1,i do ins(arp_notes, s[j]) end end end
    local rev = {}; for i=#r_notes,1,-1 do ins(rev, r_notes[i]) end
    if mod_2 then add_a(mod_1 and rev or r_notes); add_a(mod_1 and r_notes or rev) else add_a(mod_1 and rev or r_notes) end
  end

  if mod_1 and (cur_ord==1 or cur_ord==2 or cur_ord==6 or cur_ord==7) and #arp_notes>0 then
    local rev = {}; for i=#arp_notes,1,-1 do ins(rev, arp_notes[i]) end; arp_notes = rev
  end

  if cur_ord == 9 then step = find_root_step() end
end

local function chg_pg(pg)
  if act_pg == 0 and pg ~= 0 and get_phys_ct() > 0 and latch == 0 then latch = 1 end
  act_pg = pg; redraw()
end

local m, blk_m, g_off_m, blk_st = nil, nil, nil, true
local pls_v, pls_d = 2, 1
local pls_m = metro.init(function()
  pls_v = pls_v + pls_d
  if pls_v >= 10 then pls_d = -1 elseif pls_v <= 2 then pls_d = 1 end
  if act_pg == 0 or not buf_lock then redraw() end
end, 0.1); pls_m:start()

local function arp_tick()
  gate_pos = (gate_pos % gate_len) + 1
  local p_note, p_vel, p_gate, p_ch
  
  if buf_lock and buf_idx == 0 then
    buf_idx = buf_start
  else
    buf_idx = (buf_idx % 64) + 1
  end

  if not buf_lock then
    p_ch = midi_out
    if gate_seq[gate_pos] then
      if #arp_notes > 0 then
        if step > #arp_notes or step < 1 then step = (cur_ord == 9) and find_root_step() or 1 end
        if cur_ord == 10 then
          local mi, mx = 1, #arp_notes
          if mod_2 and #act_octs_ord > 0 then
            rand_oct_idx = ((rand_oct_idx - 1) % #act_octs_ord) + 1
            local chunk = max(1, flr(#arp_notes / #act_octs_ord))
            mi, mx = ((rand_oct_idx - 1) * chunk) + 1, min(#arp_notes, rand_oct_idx * chunk)
            if mi > mx then mi = mx end
            rand_cycle = rand_cycle + 1
            if rand_cycle > max(8, #press_ord * 2) then rand_cycle, rand_oct_idx = 1, (rand_oct_idx % #act_octs_ord) + 1 end
          end
          local ch = rnd(mi, mx)
          if mod_1 and (mx - mi) > 0 then
            local att = 0; while arp_notes[ch] == last_note and att < 10 do ch = rnd(mi, mx); att = att + 1 end
          end
          p_note = arp_notes[ch]
        elseif cur_ord == 9 then
          p_note = arp_notes[step]
          local amt = mod_1 and rnd(-2, 2) or rnd(-1, 1)
          step = step + amt
          if mod_2 then
            while step > #arp_notes do step = step - #arp_notes end
            while step < 1 do step = step + #arp_notes end
          else
            if step > #arp_notes then step = max(1, #arp_notes - (step - #arp_notes))
            elseif step < 1 then step = min(#arp_notes, 1 + (1 - step)) end
            step = clamp(step, 1, #arp_notes)
          end
        else
          p_note = arp_notes[step]
          local dir = 1
          local is_pend = mod_2 and cur_ord ~= 8
          if is_pend then 
            if play_dir == 1 and step >= #arp_notes then play_dir = -1 elseif play_dir == -1 and step <= 1 then play_dir = 1 end
            dir = play_dir
          else play_dir = dir end
          step = step + dir
          if step > #arp_notes then step = is_pend and max(1, #arp_notes - 1) or 1 
          elseif step < 1 then step = is_pend and min(2, #arp_notes) or #arp_notes end
        end
        p_vel, p_gate = gate_vel[gate_pos], gate_gate[gate_pos]
      else step = 1 end
    end
    hist_buf[buf_idx].n = p_note; hist_buf[buf_idx].v = p_vel
    hist_buf[buf_idx].g = p_gate; hist_buf[buf_idx].c = p_ch
  else
    if buf_start <= buf_end then 
      if buf_idx > buf_end or buf_idx < buf_start then buf_idx = buf_start end
    else 
      if buf_idx > buf_end and buf_idx < buf_start then buf_idx = buf_start end 
    end
    local rec = hist_buf[buf_idx]
    p_note, p_vel, p_gate, p_ch = rec.n, rec.v, rec.g, rec.c
  end

  local is_tie = false
  if act_note then
    if last_gate == 100 and act_note == p_note and act_note_ch == p_ch then
      is_tie = true
    else
      kill_act()
    end
  end

  if p_note then
    act_note, act_note_ch, last_note = p_note, p_ch, p_note
    if not is_tie then tx_midi(act_note, p_vel, p_ch, true) end
    if p_gate < 100 then
      local c_int = (gate_pos % 2 == 1) and (arp_speed * (swing/50)) or (arp_speed * ((100-swing)/50))
      g_off_m:start(max(0.005, c_int * (p_gate/100)), 1)
    end
    last_gate = p_gate
  else
    last_gate = 0
  end

  m.time = arp_speed * ((gate_pos % 2 == 1) and (swing/50) or ((100-swing)/50))
  redraw()
end

m = metro.init(arp_tick, arp_speed)
blk_m = metro.init(function() blk_st = not blk_st; redraw() end, (60/bpm)/2)
g_off_m = metro.init(function() kill_act(); redraw() end, 0.1, 1)

local midi_clk_m = metro.init(function()
  if clk_src == 1 and send_midi_clk then tx_midi_sys(248) end
end, (60/bpm)/24)
midi_clk_m:start()

local function upd_tempo()
  local mult = 4 / (2^(div_idx-1))
  if mod_mode == 2 then mult = mult * (2/3) elseif mod_mode == 3 then mult = mult * 1.5 end
  arp_speed = (60/bpm) * mult
  m.time = arp_speed * (((gate_pos==0 and 1 or gate_pos) % 2 == 1) and (swing/50) or ((100-swing)/50))
  blk_m.time = (60/bpm)/2
  midi_clk_m.time = (60/bpm)/24
  if clk_src == 1 and playing then m:start() else m:stop() end
end

local function reset_defaults()
  kill_act(); clear_log_keys()
  bpm, clk_src, send_midi_clk, div_idx, mod_mode, swing = 120, 1, true, 5, 1, 50
  cur_ord, mod_1, mod_2 = 1, false, false
  gate_len, glb_vel, glb_gate = 16, 96, 50
  for i=1,64 do gate_seq[i], gate_vel[i], gate_gate[i] = true, glb_vel, glb_gate end
  act_octs = {[-2]=false, [-1]=false, [0]=true, [1]=false, [2]=false}
  act_octs_ord = {0}
  log_keys, phys_keys, press_ord, arp_notes = {}, {}, {}, {}
  step, gate_pos, buf_idx, buf_lock = 1, 0, 0, false
  hist_buf, buf_held = {}, {}
  for i=1,64 do hist_buf[i] = {n=nil, v=0, g=0, c=1} end
  latch, oct_shift, last_gate = 0, 0, 0
  midi_out, midi_in, midi_focus = 1, 0, 2
  upd_tempo(); rebuild_arp()
end

local function soft_reset()
  kill_act(); clear_log_keys()
  gate_len = 16
  for i=1,64 do gate_seq[i], gate_vel[i], gate_gate[i] = true, glb_vel, glb_gate end
  act_octs = {[-2]=false, [-1]=false, [0]=true, [1]=false, [2]=false}
  act_octs_ord = {0}
  log_keys, phys_keys, press_ord, arp_notes = {}, {}, {}, {}
  latch, oct_shift, last_gate = 0, 0, 0
  step, gate_pos = (cur_ord == 9) and find_root_step() or 1, 0
  rebuild_arp()
end

local function save_pr(n)
  local p = {b=bpm, d=div_idx, s=swing, mc=send_midi_clk, o=cur_ord, m1=mod_1, m2=mod_2, gl=gate_len, gs={}, gv={}, gg={}, ao={}, aoo={}, l=latch, po={}}
  for i=1,64 do 
    p.gs[i] = gate_seq[i]
    if gate_vel[i] ~= glb_vel then p.gv[i] = gate_vel[i] end
    if gate_gate[i] ~= glb_gate then p.gg[i] = gate_gate[i] end
  end
  for i=-2,2 do p.ao[i] = act_octs[i] end
  for i=1,#act_octs_ord do p.aoo[i] = act_octs_ord[i] end
  for i=1,#press_ord do p.po[i] = press_ord[i] end
  
  pset_write(n, p)
  presets[n] = true
  pset_write(100, {cur_pr = n})
  cur_pr = n
  collectgarbage("collect")
end

local function load_pr(n)
  local p = pset_read(n)
  if not p then 
    reset_defaults()
    cur_pr = n
    pset_write(100, {cur_pr = n})
    return 
  end
  kill_act(); clear_log_keys()
  
  bpm, div_idx, swing, cur_ord, mod_1, mod_2, gate_len, latch = p.b, p.d, p.s, p.o, p.m1, p.m2, p.gl, p.l
  send_midi_clk = p.mc == nil and true or p.mc
  for i=1,64 do 
    gate_seq[i] = p.gs[i]
    gate_vel[i] = p.gv[i] or glb_vel
    gate_gate[i] = p.gg[i] or glb_gate
  end
  
  act_octs = {[-2]=false, [-1]=false, [0]=false, [1]=false, [2]=false}
  act_octs_ord, press_ord, log_keys = {}, {}, {}
  for i=-2,2 do act_octs[i] = p.ao[i] end
  for i=1,#p.aoo do act_octs_ord[i] = p.aoo[i] end
  if p.po then for i=1,#p.po do press_ord[i] = p.po[i]; log_keys[p.po[i]] = true end end
  
  last_gate = 0
  cur_pr = n
  pset_write(100, {cur_pr = n})
  
  upd_tempo(); rebuild_arp(); redraw()
  collectgarbage("collect")
end

local sys_m = metro.init(function() 
  sys_t = sys_t + 0.1 
  collectgarbage("step", 100)
  
  if act_pg == 0 then
    for idx, t in pairs(gate_held) do if t and (sys_t - t) >= 1.0 then gate_len, gate_held[idx] = idx, nil; redraw() end end
  end
  if p_h_n and not p_svd and (sys_t - p_h_t) >= 2.0 then
    save_pr(p_h_n); p_svd = true; p_bl_n, p_bl_t = p_h_n, sys_t; redraw()
  end
  if play_h and not play_svd and (sys_t - play_h_t) >= 2.0 then
    soft_reset()
    if clk_src == 1 and playing and send_midi_clk then
      tx_midi_sys(252)
      tx_midi_sys(250)
    end
    play_svd = true
    play_blink_t = sys_t
    redraw()
  end
  if p_bl_n and (sys_t - p_bl_t) >= 0.75 then p_bl_n = nil; redraw() end
  if play_blink_t > 0 and (sys_t - play_blink_t) >= 0.75 then play_blink_t = 0; redraw() end
end, 0.1)

function event_midi(d1, d2, d3)
  if clk_src == 2 then
    if d1 == 248 and playing then
      ext_tick = ext_tick + 1
      local mult = 4 / (2^(div_idx-1)); if mod_mode==2 then mult=mult*(2/3) elseif mod_mode==3 then mult=mult*1.5 end
      local tgt = 24 * mult * (((gate_pos==0 and 1 or gate_pos) % 2 == 1) and (swing/50) or ((100-swing)/50))
      if ext_tick >= tgt then ext_tick = 0; arp_tick() end
    elseif d1 == 250 or d1 == 251 then playing, ext_tick, gate_pos, buf_idx, step = true, 0, 0, 0, 1; if cur_ord==9 then step=find_root_step() end; redraw()
    elseif d1 == 252 then playing = false; kill_act(); redraw() end
  end
  local is_on, is_off = (d1>=144 and d1<=159), (d1>=128 and d1<=143)
  if is_on or is_off then
    if midi_in == -1 or (midi_in > 0 and (d1%16)+1 ~= midi_in) then return end
    local note, vel, k_id = d2, d3, 2000+d2
    if is_on and vel > 0 then
      if latch == 2 and get_phys_ct() == 0 then clear_log_keys() end
      phys_keys[k_id] = note
      if latch == 1 then if log_keys[note] then log_keys[note]=nil; for i,v in ipairs(press_ord) do if v==note then rem(press_ord,i) break end end else log_keys[note]=true; ins(press_ord, note) end
      else log_keys[note]=true; ins(press_ord, note) end
      step = (cur_ord == 9) and find_root_step() or 1; rebuild_arp(); redraw()
    elseif phys_keys[k_id] then
      phys_keys[k_id] = nil
      if latch == 0 then
        log_keys[note]=nil; for i,v in ipairs(press_ord) do if v==note then rem(press_ord,i) break end end
        step = (cur_ord == 9) and find_root_step() or 1; rebuild_arp()
        if #arp_notes == 0 and act_note then kill_act() end
      end
      redraw()
    end
  end
end

function event_grid(x, y, z)
  if z == 0 then
    local bn = key_map[y] and key_map[y][x]
    if bn then
      if pr_mode and p_h_n == bn then
        if not p_svd then load_pr(bn) end
        p_h_n = nil; redraw()
      end
      if phys_keys[(x*100)+y] then
        local note = phys_keys[(x*100)+y]; phys_keys[(x*100)+y] = nil
        if latch == 0 then 
          log_keys[note]=nil; for i,v in ipairs(press_ord) do if v==note then rem(press_ord,i) break end end
          step = (cur_ord == 9) and find_root_step() or 1; rebuild_arp()
          if #arp_notes == 0 and act_note then kill_act() end
        end
        redraw()
      end
    end
  end

  if y == 1 then
    if x >= 8 and x <= 12 and z == 1 then
      local oct = x - 10
      if act_octs[oct] then
        act_octs[oct] = false
        for i,v in ipairs(act_octs_ord) do if v==oct then rem(act_octs_ord,i); break end end
      else act_octs[oct] = true; ins(act_octs_ord, oct) end
      local any = false; for o=-2,2 do if act_octs[o] then any=true break end end
      if not any then act_octs[0]=true; ins(act_octs_ord,0) end
      rebuild_arp(); redraw()
    elseif x == 14 then 
      edit_h = (z == 1)
      if z == 1 then 
        edit_u = false 
      else
        if not edit_u then chg_pg(act_pg == 4 and 0 or 4) end
      end
      redraw()
      return
    else
      local p_m = {[3]=1, [5]=2, [4]=3, [15]=5, [7]=6}
      if x == 1 then
        play_h = (z == 1)
        if z == 1 then 
          play_h_t = sys_t; play_svd = false
        else
          if not play_svd then
            playing = not playing
            if playing then
              if clk_src == 1 then
                if send_midi_clk then tx_midi_sys(250) end
                m:start()
                if cur_ord==9 then step=find_root_step() end
              end
            else
              if clk_src == 1 and send_midi_clk then tx_midi_sys(252) end
              if clk_src == 1 then m:stop() end
              kill_act()
            end
          end
        end
        redraw()
      elseif z == 1 then
        if x == 2 then 
          gate_pos, buf_idx = 0, 0
          step = (cur_ord == 9) and find_root_step() or 1
          if clk_src == 1 and playing and send_midi_clk then
            tx_midi_sys(252)
            tx_midi_sys(250)
          end
          redraw()
        elseif p_m[x] then chg_pg(act_pg == p_m[x] and 0 or p_m[x])
        elseif x == 16 then 
          if buf_lock and act_pg ~= 0 then 
             chg_pg(0)
          else 
             buf_lock = not buf_lock
             buf_held = {}
             if not buf_lock then buf_start, buf_end = 1, 64 else chg_pg(0) end 
          end
          redraw()
        end
      end
    end
    return
  end

  if act_pg == 1 and z == 1 then
    if y == 2 then
      if x == 1 then
        if #taps > 0 and (sys_t - taps[#taps]) > 2.0 then taps = {} end
        if #taps > 0 and (sys_t - taps[#taps]) < 0.1 then return end
        ins(taps, sys_t)
        if #taps > 1 then local d = (sys_t - taps[1]) / (#taps - 1); if d > 0 then bpm = flr(clamp(60/d, 20, 300)); upd_tempo() end end
        if #taps > 4 then rem(taps, 1) end
      elseif x == 3 or x == 4 then clk_src = (x==3) and 1 or 2; upd_tempo() 
      elseif x == 16 and clk_src == 1 then send_midi_clk = not send_midi_clk
      end
    elseif x == 13 and clk_src == 1 then
      local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 10) or (y==8 and -10)
      if d then bpm = clamp(bpm+d, 20, 300); upd_tempo() end
    end
    redraw(); return 
  elseif act_pg == 2 and z == 1 and y == 2 then
    if x>=1 and x<=7 then div_idx = x; upd_tempo() elseif x>=14 and x<=16 then mod_mode = x-13; upd_tempo() end
    redraw(); return
  elseif act_pg == 3 and z == 1 and x == 13 then
    local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 5) or (y==8 and -5)
    if d then swing = clamp(swing+d, 25, 75); upd_tempo(); redraw() end
    return
  elseif act_pg == 4 then
    if y >= 2 and y <= 5 and z == 1 then edit_step = x + ((y-2)*16); redraw(); return end
    if y == 7 and z == 1 then
      local v = min(127, x*8)
      if edit_h then edit_u=true; glb_vel=v; for i=1,64 do gate_vel[i]=v end else gate_vel[edit_step]=v end
      redraw(); return
    end
    if y == 8 and z == 1 then
      local g = flr((x/16)*100)
      if edit_h then edit_u=true; glb_gate=g; for i=1,64 do gate_gate[i]=g end else gate_gate[edit_step]=g end
      redraw(); return
    end
  elseif act_pg == 5 and z == 1 then
    if y == 2 and (x==1 or x==2) then midi_focus = x
    elseif x == 13 then
      local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 5) or (y==8 and -5)
      if d then if midi_focus==1 then midi_in=clamp(midi_in+d,-1,16) else midi_out=clamp(midi_out+d,-1,16) end end
    end
    redraw(); return
  elseif act_pg == 6 and z == 1 and y == 2 then
    if x >= 1 and x <= #play_ords then cur_ord = x; rebuild_arp(); if cur_ord==9 then step=find_root_step() end
    elseif x == 15 then mod_1 = not mod_1; step = (cur_ord==9) and find_root_step() or 1; rebuild_arp()
    elseif x == 16 then mod_2 = not mod_2; step = (cur_ord==9) and find_root_step() or 1; rebuild_arp() end
    redraw(); return
  end

  if y >= 2 and y <= 5 then
    local idx = x + ((y-2)*16)
    if buf_lock then
      if z == 1 then
        local dup = false
        for _, v in ipairs(buf_held) do if v == idx then dup = true break end end
        if not dup then ins(buf_held, idx) end
        
        if #buf_held == 1 then 
            buf_start, buf_end = buf_held[1], buf_held[1] 
        elseif #buf_held >= 2 then 
            buf_start, buf_end = buf_held[1], buf_held[#buf_held] 
        end
      else
        for k,v in ipairs(buf_held) do if v==idx then rem(buf_held,k); break end end
      end
    else
      if z == 1 then gate_held[idx] = sys_t
      elseif gate_held[idx] then if (sys_t-gate_held[idx])<1.0 then gate_seq[idx] = not gate_seq[idx] end; gate_held[idx] = nil end
    end
    redraw(); return
  end

  if x == 1 and y == 8 and z == 1 then
    if latch > 0 then
      latch = 0; clear_log_keys()
      for _, n in pairs(phys_keys) do log_keys[n]=true; ins(press_ord, n) end
      if get_phys_ct() == 0 and act_note then kill_act() end
    else
      latch = get_phys_ct()==0 and 1 or 2
      for _, n in pairs(phys_keys) do log_keys[n]=true; ins(press_ord, n) end
    end
    step = (cur_ord == 9) and find_root_step() or 1; rebuild_arp(); redraw(); return
  end
  
  if x == 2 and y == 8 and z == 1 then pr_mode = not pr_mode; redraw(); return end
  
  if x == 1 and y == 7 then oct_dn_h = (z==1); if z==1 then if get_phys_ct() > 0 and latch == 0 then latch = 1 end; oct_shift = oct_up_h and 0 or max(-4, oct_shift-1); redraw() end; return end
  if x == 2 and y == 7 then oct_up_h = (z==1); if z==1 then if get_phys_ct() > 0 and latch == 0 then latch = 1 end; oct_shift = oct_dn_h and 0 or min(4, oct_shift+1); redraw() end; return end

  local bn = key_map[y] and key_map[y][x]
  if bn and z == 1 then
    if pr_mode then p_h_n, p_h_t, p_svd = bn, sys_t, false; redraw()
    else
      local note = norm_n(note_map[y][x] + (oct_shift * 12))
      if latch == 2 and get_phys_ct() == 0 then clear_log_keys() end
      phys_keys[(x*100)+y] = note 
      if latch == 1 then if log_keys[note] then log_keys[note]=nil; for i,v in ipairs(press_ord) do if v==note then rem(press_ord,i) break end end else log_keys[note]=true; ins(press_ord, note) end else log_keys[note]=true; ins(press_ord, note) end
      step = (cur_ord == 9) and find_root_step() or 1; rebuild_arp(); redraw()
    end
  end
end

local function draw_inc_b(c) grid_led(c,4,12); grid_led(c,5,6); grid_led(c,7,12); grid_led(c,8,6) end

local function hw_redraw()
  grid_led_all(0)
  
  local play_br = playing and 15 or 4
  if play_blink_t > 0 and (sys_t - play_blink_t) < 0.75 then play_br = blk_st and 15 or 0 end
  grid_led(1, 1, play_br); grid_led(2, 1, 4)                     
  
  for _, b in ipairs(p_btns) do grid_led(b[1], 1, act_pg == b[2] and (b[2]==1 and (blk_st and 15 or 6) or 15) or (b[2]==1 and (blk_st and 8 or 2) or 4)) end
  grid_led(14, 1, act_pg == 4 and 15 or 4)
  for i=-2, 2 do grid_led(10+i, 1, act_octs[i] and 15 or (i==0 and 1 or (i%2==0 and 5 or 3))) end
  grid_led(16, 1, buf_lock and 15 or pls_v) 
  
  if act_pg == 1 then
    grid_led(1, 2, blk_st and 15 or 4); grid_led(3, 2, clk_src == 1 and 15 or 4); grid_led(4, 2, clk_src == 2 and 15 or 4) 
    if clk_src == 1 then 
      draw_inc_b(13)
      grid_led(16, 2, send_midi_clk and 15 or 1)
    end
    draw_text((clk_src == 2) and "EXT" or bpm_strs[flr(bpm + 0.5)], 1, 4)
  elseif act_pg == 2 then
    for i=1,7 do grid_led(i, 2, div_idx == i and 15 or 4) end; for i=1,3 do grid_led(i+13, 2, mod_mode == i and 15 or 4) end
    draw_text(div_strs[div_idx][mod_mode], 1, 4)
  elseif act_pg == 3 then draw_inc_b(13); draw_text(swing_strs[swing], 1, 4)
  elseif act_pg == 4 then
    local d_pos = gate_pos == 0 and 1 or gate_pos
    for i=1,64 do
      local gx, gy = (i-1)%16+1, flr((i-1)/16)+2
      if i == d_pos then grid_led(gx, gy, 15) elseif i == edit_step then grid_led(gx, gy, 10) 
      elseif i <= gate_len then grid_led(gx, gy, not gate_seq[i] and 0 or ((gate_vel[i]~=glb_vel or gate_gate[i]~=glb_gate) and 6 or 1))
      else grid_led(gx, gy, 1) end
    end
    local sx, sg = ceil(gate_vel[edit_step]/8), ceil((gate_gate[edit_step]/100)*16)
    for i=1,16 do grid_led(i, 7, i<=sx and (i==sx and 15 or 6) or 2); grid_led(i, 8, i<=sg and (i==sg and 15 or 6) or 2) end
  elseif act_pg == 5 then
    grid_led(1, 2, midi_focus == 1 and 15 or 4); grid_led(2, 2, midi_focus == 2 and 15 or 4); draw_inc_b(13)
    draw_text(ch_strs[(midi_focus == 1) and midi_in or midi_out], 1, 4)
  elseif act_pg == 6 then
    for i = 1, #play_ords do grid_led(i, 2, cur_ord == i and 15 or 4) end
    grid_led(15, 2, mod_1 and 15 or 4); grid_led(16, 2, mod_2 and 15 or 4)
    draw_text(play_ords[cur_ord], 1, 4)
  else
    local d_pos = gate_pos == 0 and 1 or gate_pos
    local d_buf = buf_idx == 0 and buf_start or buf_idx
    for i=1,64 do
      local gx, gy = (i-1)%16+1, flr((i-1)/16)+2
      if buf_lock then
        local br, in_l = hist_buf[i].n and max(1, flr((hist_buf[i].v/127)*15)) or 0, false
        if buf_start <= buf_end then in_l = (i>=buf_start and i<=buf_end) else in_l = (i>=buf_start or i<=buf_end) end
        grid_led(gx, gy, i==d_buf and 15 or ((i==buf_start or i==buf_end) and pls_v or (in_l and (br>0 and br or 1) or 0)))
      else
        local br = gate_seq[i] and max(1, flr((gate_vel[i]/127)*15)) or 0
        grid_led(gx, gy, i==d_pos and 15 or (i<=gate_len and br or (gate_seq[i] and 1 or 0)))
      end
    end
    grid_led(1, 8, latch==1 and 10 or (latch==2 and 15 or 4))
    grid_led(2, 8, pr_mode and 10 or 1)
    grid_led(1, 7, (oct_shift<0) and br_map[math.abs(oct_shift)] or 2); grid_led(2, 7, (oct_shift>0) and br_map[oct_shift] or 2)
    
    if pr_mode then
      for y, r in pairs(key_map) do
        for x, slot in pairs(r) do
          local br = 1
          if p_bl_n == slot then br = blk_st and 15 or 0 elseif cur_pr == slot then br = 15 elseif presets[slot] then br = 4 end
          grid_led(x, y, br)
        end
      end
    else
      for y, r in pairs(note_map) do for x in pairs(r) do grid_led(x, y, y==8 and 3 or 1) end end
      for n in pairs(log_keys) do if note_xy[n-(oct_shift*12)] then grid_led(note_xy[n-(oct_shift*12)].x, note_xy[n-(oct_shift*12)].y, 8) end end
      if act_note and note_xy[act_note-(oct_shift*12)] then grid_led(note_xy[act_note-(oct_shift*12)].x, note_xy[act_note-(oct_shift*12)].y, 15) end
    end
  end
  grid_refresh()
end

for i=1, 24 do local d = pset_read(i); if d then presets[i] = true end end
local gst = pset_read(100)
if gst and gst.cur_pr then load_pr(gst.cur_pr) end

sys_m:start(); blk_m:start(); upd_tempo()
local rndr_m = metro.init(function() if grid_dirty then hw_redraw(); grid_dirty = false end end, 1/30); rndr_m:start()
