-- arpeggiii
local logical_keys, physical_keys, pressed_order, arp_notes = {}, {}, {}, {}
local step, active_note, active_note_channel, last_played_note = 1, nil, 1, nil
local latch_mode, octave_shift, oct_down_held, oct_up_held = 0, 0, false, false
local midi_out_channel, midi_in_channel, midi_focus = 1, 0, 2
local active_octaves, active_octaves_order = {[-2]=false, [-1]=false, [0]=true, [1]=false, [2]=false}, {0}
local playing, active_page = true, 0
local bpm, clock_source, active_div_idx, modifier_mode, swing_val = 120, 1, 4, 1, 50
local arp_speed, sys_time, ext_tick_counter, taps = (60/bpm)/2, 0, 0, {}
local play_orders = {"ORDR", "LINE", "LEAP", "STAG", "SHFT", "SPRL", "ANCH", "ACCM", "WALK", "RAND"}
local current_order, mod_1, mod_2 = 1, false, false
local play_dir, rand_oct_idx, rand_cycle = 1, 1, 1

local gate_seq, gate_vel, gate_gate, gate_held = {}, {}, {}, {}
local global_vel, global_gate, gate_len, gate_pos = 96, 50, 16, 0
for i=1,64 do gate_seq[i], gate_vel[i], gate_gate[i] = true, global_vel, global_gate end

local history_buffer, buf_held = {}, {}
for i=1,64 do history_buffer[i] = {n=nil, v=0, g=0, c=1} end
local buf_idx, buffer_locked, buf_start, buf_end = 0, false, 1, 64
local edit_step, edit_page_held, edit_page_used = 1, false, false

local font = {
  [48]="011101101101110", [49]="010110010010111", [50]="110001111100111", [51]="110001111001111", 
  [52]="101101111001001", [53]="111100111001110", [54]="011100111101111", [55]="111001010010010", 
  [56]="011101111101110", [57]="111101111001110", [45]="000000111000000", [43]="000010111010000", 
  [69]="111100110100111", [88]="101101010101101", [84]="111010010010010", [46]="000000000000010", 
  [47]="001001010100100", [37]="101001010100101", [65]="011101111101101", [76]="100100100100111", 
  [68]="110101101101110", [79]="011101101101110", [87]="101101101111101", [78]="110101101101101", 
  [85]="101101101101011", [80]="011101111100100", [82]="011101110101101", [89]="101101111001110", 
  [70]="111100111100100", [67]="011101100101110", [73]="111010010010111", [86]="101101101101010", 
  [71]="011100101101111", [72]="101101111101101", [83]="011100010001110", [77]="101111101101101",
  [75]="101101110101101"
}
local bright_map = {[0]=2, [1]=5, [2]=8, [3]=12, [4]=15} 
local div_strs = {{ "/1","/1T","/1."}, {"/2","/2T","/2."}, {"/4","/4T","/4."}, {"/8","/8T","/8."}, {"/16","/16T","/16."}, {"/32","/32T","/32."}}
local bpm_strs, swing_strs, ch_strs = {}, {}, {[-1]="OFF", [0]="ALL"}
for i=20,300 do bpm_strs[i]=tostring(i) end
for i=25,75 do swing_strs[i]=tostring(i).."%" end
for i=1,16 do ch_strs[i]=tostring(i) end

local key_map = {
  [8]={[3]=48,[4]=50,[5]=52,[6]=53,[7]=55,[8]=57,[9]=59,[10]=60,[11]=62,[12]=64,[13]=65,[14]=67,[15]=69,[16]=71},
  [7]={[4]=49,[5]=51,[7]=54,[8]=56,[9]=58,[11]=61,[12]=63,[14]=66,[15]=68,[16]=70}
}
local note_to_xy = {}
for y, row in pairs(key_map) do for x, n in pairs(row) do note_to_xy[n] = {x=x, y=y} end end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local grid_dirty = true
function redraw() grid_dirty = true end

local function draw_text(str, start_x, start_y)
  for c = 1, #str do
    local pat = font[string.byte(str, c)]
    if pat then 
      for i = 1, 15 do if string.byte(pat, i) == 49 then grid_led(start_x + (c-1)*4 + ((i-1)%3), start_y + math.floor((i-1)/3), 5) end end
    end
  end
end

local function kill_act_note()
  if not active_note then return end
  if active_note_channel == 0 then for c=1,16 do midi_note_off(active_note, 0, c) end
  else midi_note_off(active_note, 0, active_note_channel) end
  active_note = nil
end

local function get_physical_count()
  local count = 0; for _ in pairs(physical_keys) do count = count + 1 end; return count
end

local function clear_logical_notes()
  for note in pairs(logical_keys) do
    if midi_out_channel == 0 then for c=1,16 do midi_note_off(note,0,c) end else midi_note_off(note,0,midi_out_channel) end
  end
  logical_keys, pressed_order = {}, {}
end

local function add_logical_note(note)
  if not logical_keys[note] then logical_keys[note] = true; table.insert(pressed_order, note) end
end

local function remove_logical_note(note)
  if logical_keys[note] then
    logical_keys[note] = nil
    for i, v in ipairs(pressed_order) do if v == note then table.remove(pressed_order, i); break end end
  end
end

local function rebuild_arp()
  for i=1,#arp_notes do arp_notes[i]=nil end
  local octs, raw_notes = {}, {}
  if active_octaves[0] then table.insert(octs, 0) end
  for _, o in ipairs(active_octaves_order) do if o ~= 0 then table.insert(octs, o) end end
  
  for _, oct in ipairs(octs) do
    for _, note in ipairs(pressed_order) do
      local sn = note + (oct * 12)
      while sn > 127 do sn = sn - 120 end
      while sn < 0 do sn = sn + 120 end
      table.insert(raw_notes, sn)
    end
  end

  if current_order == 1 then -- ORDR
    for _,v in ipairs(raw_notes) do table.insert(arp_notes, v) end
  elseif current_order == 2 then -- LINE
    for _,v in ipairs(raw_notes) do table.insert(arp_notes, v) end
    table.sort(arp_notes)
  elseif current_order == 3 then -- LEAP
    local sorted = {}; for _,v in ipairs(raw_notes) do table.insert(sorted,v) end
    if mod_1 then table.sort(sorted, function(a,b) return a>b end)
    else table.sort(sorted) end
    if #sorted > 0 then
      if #sorted <= 2 then
        for _,v in ipairs(sorted) do table.insert(arp_notes, v) end
      else
        local c, is_up = 1, true
        table.insert(arp_notes, sorted[c])
        while true do
          c = is_up and (c + 2) or (c - 1)
          if c > #sorted then break end
          table.insert(arp_notes, sorted[c])
          is_up = not is_up
        end
      end
    end
  elseif current_order == 4 then -- STAG
    local sorted = {}; for _,v in ipairs(raw_notes) do table.insert(sorted,v) end
    if mod_1 then table.sort(sorted, function(a,b) return a>b end)
    else table.sort(sorted) end
    if #sorted > 0 then
      if #sorted < 3 then
        for _,v in ipairs(sorted) do table.insert(arp_notes, v) end
      else
        for i = 1, #sorted - 2 do
          table.insert(arp_notes, sorted[i])
          table.insert(arp_notes, sorted[i+1])
          table.insert(arp_notes, sorted[i+2])
        end
      end
    end
  elseif current_order == 5 then -- SHFT
    local sorted = {}; for _,v in ipairs(raw_notes) do table.insert(sorted,v) end
    if mod_1 then table.sort(sorted, function(a,b) return a>b end)
    else table.sort(sorted) end
    if #sorted > 0 then
      if #sorted < 4 then
        for _,v in ipairs(sorted) do table.insert(arp_notes, v) end
      else
        for i = 1, #sorted - 3 do
          table.insert(arp_notes, sorted[i])
          table.insert(arp_notes, sorted[i+1])
          table.insert(arp_notes, sorted[i+2])
          table.insert(arp_notes, sorted[i+3])
        end
      end
    end
  elseif current_order == 6 then -- SPRL
    local sorted = {}; for _,v in ipairs(raw_notes) do table.insert(sorted,v) end
    table.sort(sorted)
    local start_high = false
    if #sorted > 0 and raw_notes[1] >= (sorted[1] + sorted[#sorted]) / 2 then start_high = true end
    local l, r = 1, #sorted
    while l <= r do
      if l==r then table.insert(arp_notes, sorted[l]) 
      else 
        if start_high then table.insert(arp_notes, sorted[r]); table.insert(arp_notes, sorted[l])
        else table.insert(arp_notes, sorted[l]); table.insert(arp_notes, sorted[r]) end
      end
      l, r = l+1, r-1
    end
  elseif current_order == 7 then -- ANCH
    local anch, targets = raw_notes[1], {}
    for i=2,#raw_notes do table.insert(targets, raw_notes[i]) end
    table.sort(targets)
    if #targets > 0 then
      for _, t in ipairs(targets) do table.insert(arp_notes, anch); table.insert(arp_notes, t) end
    elseif anch then table.insert(arp_notes, anch) end
  elseif current_order == 8 then -- ACCM
    local seq, seq_rev = {}, {}
    for _,v in ipairs(raw_notes) do table.insert(seq, v) end
    for i=#seq, 1, -1 do table.insert(seq_rev, seq[i]) end
    
    local function add_accm(s)
      if #s > 0 then for i=1,#s do for j=1,i do table.insert(arp_notes, s[j]) end end end
    end
    
    if mod_2 then
      if mod_1 then add_accm(seq_rev); add_accm(seq)
      else add_accm(seq); add_accm(seq_rev) end
    else
      if mod_1 then add_accm(seq_rev)
      else add_accm(seq) end
    end
  elseif current_order == 9 then -- WALK
    local active_oct_list = {}
    if active_octaves[0] then table.insert(active_oct_list, 0) end
    for _, o in ipairs(active_octaves_order) do if o ~= 0 then table.insert(active_oct_list, o) end end
    if mod_1 then
      local rev_octs = {}
      for i=#active_oct_list, 1, -1 do table.insert(rev_octs, active_oct_list[i]) end
      active_oct_list = rev_octs
    end

    if #pressed_order > 0 and #active_oct_list > 0 then
      local oct_chunks = {}
      for _, oct in ipairs(active_oct_list) do
        local chunk = {}
        for _, note in ipairs(pressed_order) do
          local sn = note + (oct * 12)
          while sn > 127 do sn = sn - 120 end
          while sn < 0 do sn = sn + 120 end
          table.insert(chunk, sn)
        end
        table.insert(oct_chunks, chunk)
      end

      local cur_oct_idx = 1
      local cur_chunk = oct_chunks[cur_oct_idx]
      local w_idx = 1
      local chunk_step_count = 0
      local stay_length = math.max(4, #pressed_order * 2)

      for i = 1, 64 do
        table.insert(arp_notes, cur_chunk[w_idx])
        chunk_step_count = chunk_step_count + 1

        if chunk_step_count >= stay_length and #oct_chunks > 1 then
          chunk_step_count = 0
          cur_oct_idx = (cur_oct_idx % #oct_chunks) + 1
          cur_chunk = oct_chunks[cur_oct_idx]
          w_idx = 1
        end

        local r = math.random(1, 100)
        if r <= 34 then
          w_idx = w_idx + 1
        elseif r <= 68 then
          w_idx = w_idx - 1
        else
        end

        if w_idx > #cur_chunk then
          w_idx = math.max(1, #cur_chunk - 1)
        elseif w_idx < 1 then
          w_idx = math.min(#cur_chunk, 2)
        end
      end
    end
  elseif current_order == 10 then -- RAND
    for _,v in ipairs(raw_notes) do table.insert(arp_notes, v) end
    table.sort(arp_notes)
  end

  if mod_1 and current_order ~= 3 and current_order ~= 4 and current_order ~= 5 and current_order ~= 8 and current_order ~= 9 and current_order ~= 10 and #arp_notes > 0 then
    local reversed = {}
    for i=#arp_notes, 1, -1 do table.insert(reversed, arp_notes[i]) end
    arp_notes = reversed
  end
end

local function change_page(pg)
  if active_page == 0 and pg ~= 0 and get_physical_count() > 0 and latch_mode == 0 then latch_mode = 1 end
  active_page = pg; redraw()
end

local m, blink_m, gate_off_m, blink_state = nil, nil, nil, true
local pulse_val, pulse_dir = 2, 1
local pulse_m = metro.init(function()
  pulse_val = pulse_val + pulse_dir
  if pulse_val >= 10 then pulse_dir = -1 elseif pulse_val <= 2 then pulse_dir = 1 end
  if active_page == 0 or not buffer_locked then redraw() end
end, 0.1)
pulse_m:start()

local function arp_tick()
  gate_pos = (gate_pos % gate_len) + 1
  kill_act_note()
  
  local p_note, p_vel, p_gate, p_chan
  buf_idx = (buf_idx % 64) + 1

  if not buffer_locked then
    p_chan = midi_out_channel
    if gate_seq[gate_pos] then
      if #arp_notes > 0 then
        if step > #arp_notes then step = 1 end
        
        if current_order == 10 then
          local min_i, max_i = 1, #arp_notes
          if mod_2 and #active_octaves_order > 0 then
            rand_oct_idx = ((rand_oct_idx - 1) % #active_octaves_order) + 1
            local chunk = math.max(1, math.floor(#arp_notes / #active_octaves_order))
            min_i, max_i = ((rand_oct_idx - 1) * chunk) + 1, math.min(#arp_notes, rand_oct_idx * chunk)
            if min_i > max_i then min_i = max_i end
            
            rand_cycle = rand_cycle + 1
            local lock_len = math.max(8, #pressed_order * 2) 
            if rand_cycle > lock_len then 
              rand_cycle, rand_oct_idx = 1, (rand_oct_idx % #active_octaves_order) + 1 
            end
          end
          local ch = math.random(min_i, max_i)
          if mod_1 and (max_i - min_i) > 0 then
            local att = 0
            while arp_notes[ch] == last_played_note and att < 10 do
              ch = math.random(min_i, max_i)
              att = att + 1
            end
          end
          p_note = arp_notes[ch]
        else
          p_note = arp_notes[step]
          
          local dir = 1
          local is_pendulum = mod_2 and current_order ~= 8
          if is_pendulum then 
            if play_dir == 1 and step >= #arp_notes then play_dir = -1 elseif play_dir == -1 and step <= 1 then play_dir = 1 end
            dir = play_dir
          else play_dir = dir end
          step = step + dir
          if step > #arp_notes then step = is_pendulum and math.max(1, #arp_notes - 1) or 1 
          elseif step < 1 then step = is_pendulum and math.min(2, #arp_notes) or #arp_notes end
        end
        p_vel, p_gate = gate_vel[gate_pos], gate_gate[gate_pos]
      else step = 1 end
    end
    history_buffer[buf_idx].n = p_note; history_buffer[buf_idx].v = p_vel
    history_buffer[buf_idx].g = p_gate; history_buffer[buf_idx].c = p_chan
  else
    if buf_start <= buf_end then if buf_idx > buf_end or buf_idx < buf_start then buf_idx = buf_start end
    else if buf_idx > buf_end and buf_idx < buf_start then buf_idx = buf_start end end
    local rec = history_buffer[buf_idx]
    p_note, p_vel, p_gate, p_chan = rec.n, rec.v, rec.g, rec.c
  end

  if p_note then
    active_note, active_note_channel, last_played_note = p_note, p_chan, p_note
    if p_chan == 0 then for c=1,16 do midi_note_on(active_note, p_vel, c) end else midi_note_on(active_note, p_vel, p_chan) end
    local c_int = (gate_pos % 2 == 1) and (arp_speed * (swing_val/50)) or (arp_speed * ((100-swing_val)/50))
    gate_off_m:start(math.max(0.005, c_int * (p_gate/100)), 1)
  end
  m.time = arp_speed * ((gate_pos % 2 == 1) and (swing_val/50) or ((100-swing_val)/50))
  redraw()
end

m = metro.init(arp_tick, arp_speed)
blink_m = metro.init(function() blink_state = not blink_state; redraw() end, (60/bpm)/2)
gate_off_m = metro.init(function() kill_act_note(); redraw() end, 0.1, 1)

local function update_tempo()
  local mult = 4 / (2^(active_div_idx-1))
  if modifier_mode == 2 then mult = mult * (2/3) elseif modifier_mode == 3 then mult = mult * 1.5 end
  arp_speed = (60/bpm) * mult
  m.time = arp_speed * (((gate_pos==0 and 1 or gate_pos) % 2 == 1) and (swing_val/50) or ((100-swing_val)/50))
  blink_m.time = (60/bpm)/2
  if clock_source == 1 and playing then m:start() else m:stop() end
end

local sys_m = metro.init(function() 
  sys_time = sys_time + 0.1 
  if active_page == 0 then
    for idx, t in pairs(gate_held) do
      if t and (sys_time - t) >= 1.0 then gate_len, gate_held[idx] = idx, nil; redraw() end
    end
  end
end, 0.1)
sys_m:start(); blink_m:start(); update_tempo()

function event_midi(d1, d2, d3)
  if clock_source == 2 then
    if d1 == 248 and playing then
      ext_tick_counter = ext_tick_counter + 1
      local mult = 4 / (2^(active_div_idx-1))
      if modifier_mode == 2 then mult = mult * (2/3) elseif modifier_mode == 3 then mult = mult * 1.5 end
      local tgt = 24 * mult * (((gate_pos==0 and 1 or gate_pos) % 2 == 1) and (swing_val/50) or ((100-swing_val)/50))
      if ext_tick_counter >= tgt then ext_tick_counter = 0; arp_tick() end
    elseif d1 == 250 or d1 == 251 then playing, ext_tick_counter, gate_pos, buf_idx, step = true, 0, 0, 0, 1; redraw()
    elseif d1 == 252 then playing = false; kill_act_note(); redraw() end
  end
  local is_on, is_off = (d1>=144 and d1<=159), (d1>=128 and d1<=143)
  if is_on or is_off then
    if midi_in_channel == -1 or (midi_in_channel > 0 and (d1%16)+1 ~= midi_in_channel) then return end
    local note, vel, k_id = d2, d3, 2000+d2
    if is_on and vel > 0 then
      if latch_mode == 2 and get_physical_count() == 0 then clear_logical_notes() end
      physical_keys[k_id] = note
      if latch_mode == 1 then if logical_keys[note] then remove_logical_note(note) else add_logical_note(note) end
      else add_logical_note(note) end
      step = 1; rebuild_arp(); redraw()
    elseif physical_keys[k_id] then
      physical_keys[k_id] = nil
      if latch_mode == 0 then
        remove_logical_note(note); step = 1; rebuild_arp()
        if #arp_notes == 0 and active_note then kill_act_note() end
      end
      redraw()
    end
  end
end

function event_grid(x, y, z)
  if z == 0 then
    local bn = (key_map[y] and key_map[y][x])
    if bn and physical_keys[(x*100)+y] then
      local note = physical_keys[(x*100)+y]; physical_keys[(x*100)+y] = nil
      if latch_mode == 0 then 
        remove_logical_note(note); step = 1; rebuild_arp()
        if #arp_notes == 0 and active_note then kill_act_note() end
      end
      redraw()
    end
  end

  if y == 1 then
    if x >= 8 and x <= 12 and z == 1 then
      local oct = x - 10
      if active_octaves[oct] then
        active_octaves[oct] = false
        for i,v in ipairs(active_octaves_order) do if v==oct then table.remove(active_octaves_order,i); break end end
      else active_octaves[oct] = true; table.insert(active_octaves_order, oct) end
      local any = false; for o=-2,2 do if active_octaves[o] then any=true break end end
      if not any then active_octaves[0]=true; table.insert(active_octaves_order,0) end
      rebuild_arp(); redraw()
    elseif x == 14 then
      edit_page_held, edit_page_used = (z==1), false
      if z==0 and not edit_page_used then change_page(active_page == 4 and 0 or 4) end
    elseif z == 1 then
      if x == 1 then
        playing = not playing
        if playing then if clock_source==1 then m:start() end else m:stop(); kill_act_note() end; redraw()
      elseif x == 2 then gate_pos, buf_idx, step = 0, 0, 1; redraw()
      elseif x == 3 then change_page(active_page == 1 and 0 or 1)
      elseif x == 4 then change_page(active_page == 2 and 0 or 2)
      elseif x == 5 then change_page(active_page == 3 and 0 or 3)
      elseif x == 7 then change_page(active_page == 6 and 0 or 6)
      elseif x == 15 then change_page(active_page == 5 and 0 or 5)
      elseif x == 16 then 
        if buffer_locked and active_page ~= 0 then change_page(0)
        else buffer_locked = not buffer_locked; if not buffer_locked then buf_start, buf_end, buf_held = 1, 64, {} else change_page(0) end end
        redraw()
      end
    end
    return 
  end

  if active_page == 1 and z == 1 then
    if y == 2 then
      if x == 1 then
        if #taps > 0 and (sys_time - taps[#taps]) > 2.0 then
          taps = {}
        end
        if #taps > 0 and (sys_time - taps[#taps]) < 0.1 then return end
        table.insert(taps, sys_time)
        if #taps > 1 then local d = (sys_time - taps[1]) / (#taps - 1); if d > 0 then bpm = math.floor(clamp(60/d, 20, 300)); update_tempo() end end
        if #taps > 4 then table.remove(taps, 1) end
      elseif x == 3 or x == 4 then clock_source = (x==3) and 1 or 2; update_tempo() end
    elseif x == 13 and clock_source == 1 then
      if y==4 then bpm=clamp(bpm+1,20,300) elseif y==5 then bpm=clamp(bpm-1,20,300) elseif y==7 then bpm=clamp(bpm+10,20,300) elseif y==8 then bpm=clamp(bpm-10,20,300) end
      update_tempo()
    end
    redraw(); return 
  elseif active_page == 2 and z == 1 and y == 2 then
    if x>=1 and x<=6 then active_div_idx = x; update_tempo() elseif x>=8 and x<=10 then modifier_mode = x-7; update_tempo() end
    redraw(); return
  elseif active_page == 3 and z == 1 and x == 13 then
    if y==4 then swing_val=clamp(swing_val+1,25,75) elseif y==5 then swing_val=clamp(swing_val-1,25,75) elseif y==7 then swing_val=clamp(swing_val+5,25,75) elseif y==8 then swing_val=clamp(swing_val-5,25,75) end
    update_tempo(); redraw(); return
  elseif active_page == 4 then
    if y >= 2 and y <= 5 and z == 1 then edit_step = x + ((y-2)*16); redraw(); return end
    if y == 7 and z == 1 then
      local v = math.min(127, x*8)
      if edit_page_held then edit_page_used=true; global_vel=v; for i=1,64 do gate_vel[i]=v end else gate_vel[edit_step]=v end
      redraw(); return
    end
    if y == 8 and z == 1 then
      local g = math.floor((x/16)*100)
      if edit_page_held then edit_page_used=true; global_gate=g; for i=1,64 do gate_gate[i]=g end else gate_gate[edit_step]=g end
      redraw(); return
    end
  elseif active_page == 5 and z == 1 then
    if y == 2 then if x==1 then midi_focus=1 elseif x==2 then midi_focus=2 end
    elseif x == 13 then
      if y == 4 then if midi_focus==1 then midi_in_channel=clamp(midi_in_channel+1,-1,16) else midi_out_channel=clamp(midi_out_channel+1,-1,16) end
      elseif y == 5 then if midi_focus==1 then midi_in_channel=clamp(midi_in_channel-1,-1,16) else midi_out_channel=clamp(midi_out_channel-1,-1,16) end
      elseif y == 7 then if midi_focus==1 then midi_in_channel=clamp(midi_in_channel+5,-1,16) else midi_out_channel=clamp(midi_out_channel+5,-1,16) end
      elseif y == 8 then if midi_focus==1 then midi_in_channel=clamp(midi_in_channel-5,-1,16) else midi_out_channel=clamp(midi_out_channel-5,-1,16) end end
    end
    redraw(); return
  elseif active_page == 6 and z == 1 and y == 2 then
    if x >= 1 and x <= #play_orders then current_order = x; rebuild_arp()
    elseif x == 15 then mod_1 = not mod_1; step = 1; rebuild_arp()
    elseif x == 16 then mod_2 = not mod_2; step = 1; rebuild_arp() end
    redraw(); return
  end

  if y >= 2 and y <= 5 then
    local idx = x + ((y-2)*16)
    if buffer_locked then
      if z == 1 then
        table.insert(buf_held, idx)
        if #buf_held==1 then buf_start,buf_end=idx,idx elseif #buf_held>=2 then buf_start,buf_end = buf_held[1],buf_held[2] end
      else for k,v in ipairs(buf_held) do if v==idx then table.remove(buf_held,k); break end end end
    else
      if z == 1 then gate_held[idx] = sys_time
      elseif gate_held[idx] then if (sys_time-gate_held[idx])<1.0 then gate_seq[idx] = not gate_seq[idx] end; gate_held[idx] = nil end
    end
    redraw(); return
  end

  if x == 1 and y == 8 and z == 1 then
    if latch_mode > 0 then
      latch_mode = 0; clear_logical_notes()
      for _, n in pairs(physical_keys) do add_logical_note(n) end
      if get_physical_count() == 0 and active_note then kill_act_note() end
    else
      latch_mode = get_physical_count()==0 and 1 or 2
      for _, n in pairs(physical_keys) do add_logical_note(n) end
    end
    step = 1; rebuild_arp(); redraw(); return
  end
  
  if x == 1 and y == 7 then oct_down_held = (z==1); if z==1 then octave_shift = oct_up_held and 0 or math.max(-4, octave_shift-1); redraw() end; return end
  if x == 2 and y == 7 then oct_up_held = (z==1); if z==1 then octave_shift = oct_down_held and 0 or math.min(4, octave_shift+1); redraw() end; return end

  local base_note = key_map[y] and key_map[y][x]
  if base_note and z == 1 then
    local note = base_note + (octave_shift * 12)
    while note > 127 do note = note - 120 end; while note < 0 do note = note + 120 end
    if latch_mode == 2 and get_physical_count() == 0 then clear_logical_notes() end
    physical_keys[(x*100)+y] = note 
    if latch_mode == 1 then if logical_keys[note] then remove_logical_note(note) else add_logical_note(note) end else add_logical_note(note) end
    step = 1; rebuild_arp(); redraw()
  end
end

local function hardware_redraw()
  grid_led_all(0)
  grid_led(1, 1, playing and 15 or 4); grid_led(2, 1, 4)                     
  grid_led(3, 1, active_page == 1 and (blink_state and 15 or 6) or (blink_state and 8 or 2)) 
  grid_led(4, 1, active_page == 2 and 15 or 4); grid_led(5, 1, active_page == 3 and 15 or 4); grid_led(7, 1, active_page == 6 and 15 or 4) 
  grid_led(8, 1, active_octaves[-2] and 15 or 5); grid_led(9, 1, active_octaves[-1] and 15 or 3)
  grid_led(10, 1, active_octaves[0] and 15 or 1); grid_led(11, 1, active_octaves[1] and 15 or 3); grid_led(12, 1, active_octaves[2] and 15 or 5)
  grid_led(14, 1, active_page == 4 and 15 or 4); grid_led(15, 1, active_page == 5 and 15 or 4); grid_led(16, 1, buffer_locked and 15 or pulse_val) 
  
  if active_page == 1 then
    grid_led(1, 2, blink_state and 15 or 4); grid_led(3, 2, clock_source == 1 and 15 or 4); grid_led(4, 2, clock_source == 2 and 15 or 4) 
    if clock_source == 1 then grid_led(13, 4, 12); grid_led(13, 5, 6); grid_led(13, 7, 12); grid_led(13, 8, 6) end
    draw_text((clock_source == 2) and "EXT" or bpm_strs[math.floor(bpm + 0.5)], 1, 4)
  elseif active_page == 2 then
    for i=1,6 do grid_led(i, 2, active_div_idx == i and 15 or 4) end; for i=1,3 do grid_led(i+7, 2, modifier_mode == i and 15 or 4) end
    draw_text(div_strs[active_div_idx][modifier_mode], 1, 4)
  elseif active_page == 3 then
    grid_led(13, 4, 12); grid_led(13, 5, 6); grid_led(13, 7, 12); grid_led(13, 8, 6)
    draw_text(swing_strs[swing_val], 1, 4)
  elseif active_page == 4 then
    for i=1,64 do
      local gx, gy = (i-1)%16+1, math.floor((i-1)/16)+2
      if i == gate_pos then grid_led(gx, gy, 15) elseif i == edit_step then grid_led(gx, gy, 10) 
      elseif i <= gate_len then grid_led(gx, gy, not gate_seq[i] and 0 or ((gate_vel[i]~=global_vel or gate_gate[i]~=global_gate) and 6 or 1))
      else grid_led(gx, gy, 1) end
    end
    local sx, sg = math.ceil(gate_vel[edit_step]/8), math.ceil((gate_gate[edit_step]/100)*16)
    for i=1,16 do grid_led(i, 7, i<=sx and (i==sx and 15 or 6) or 2); grid_led(i, 8, i<=sg and (i==sg and 15 or 6) or 2) end
  elseif active_page == 5 then
    grid_led(1, 2, midi_focus == 1 and 15 or 4); grid_led(2, 2, midi_focus == 2 and 15 or 4) 
    grid_led(13, 4, 12); grid_led(13, 5, 6)
    grid_led(13, 7, 12); grid_led(13, 8, 6)
    draw_text(ch_strs[(midi_focus == 1) and midi_in_channel or midi_out_channel], 1, 4)
  elseif active_page == 6 then
    for i = 1, #play_orders do grid_led(i, 2, current_order == i and 15 or 4) end
    grid_led(15, 2, mod_1 and 15 or 4); grid_led(16, 2, mod_2 and 15 or 4)
    draw_text(play_orders[current_order], 1, 4)
  else
    for i=1,64 do
      local gx, gy = (i-1)%16+1, math.floor((i-1)/16)+2
      if buffer_locked then
        local br, in_l = history_buffer[i].n and math.max(1, math.floor((history_buffer[i].v/127)*15)) or 0, false
        if buf_start <= buf_end then in_l = (i>=buf_start and i<=buf_end) else in_l = (i>=buf_start or i<=buf_end) end
        grid_led(gx, gy, i==buf_idx and 15 or ((i==buf_start or i==buf_end) and pulse_val or (in_l and (br>0 and br or 1) or 0)))
      else
        local br = gate_seq[i] and math.max(1, math.floor((gate_vel[i]/127)*15)) or 0
        grid_led(gx, gy, i==gate_pos and 15 or (i<=gate_len and br or (gate_seq[i] and 1 or 0)))
      end
    end
    grid_led(1, 8, latch_mode==1 and 10 or (latch_mode==2 and 15 or 4))
    grid_led(1, 7, (octave_shift<0) and bright_map[math.abs(octave_shift)] or 2); grid_led(2, 7, (octave_shift>0) and bright_map[octave_shift] or 2)
    for y, row in pairs(key_map) do for x in pairs(row) do grid_led(x, y, y==8 and 3 or 1) end end
    for n in pairs(logical_keys) do if note_to_xy[n-(octave_shift*12)] then grid_led(note_to_xy[n-(octave_shift*12)].x, note_to_xy[n-(octave_shift*12)].y, 8) end end
    if active_note and note_to_xy[active_note-(octave_shift*12)] then grid_led(note_to_xy[active_note-(octave_shift*12)].x, note_to_xy[active_note-(octave_shift*12)].y, 15) end
  end
  grid_refresh()
end

local render_m = metro.init(function() if grid_dirty then hardware_redraw(); grid_dirty = false end end, 1/30)
render_m:start()