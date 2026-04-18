-- runtime/debug.lua
-- Debug server: event hooks, watches, command handlers, and optional TCP transport.
--
-- The server can run in two modes:
--   1. Hook-only mode (default): emits events to registered Lua callbacks.
--   2. TCP mode (requires LuaSocket): additionally streams events over a socket.
--
-- Event hooks are used by the engine and state store to emit events. The server
-- evaluates watch/watch-when declarations after each mutation and fires watch
-- events when triggered.
--
-- Accepted commands (all available in hook-only mode):
--   get-state  {pattern}  → {path: value, ...}
--   eval       {expr}     → value (pure expressions only)
--   get-log    {from, to} → log entries
--   time-travel {tick}    → frozen GameState (live state unaffected)
--   set-breakpoint {condition} → id
--   clear-breakpoint {id}
--   reload     {src}      → outcome
--
-- Emitted events (delivered to registered handlers):
--   mutation    {path, old, new, fn, tick}
--   scene-change {from, to, stack, tick}
--   message-sent {actor, msg, tick}
--   schedule-fired {name, tick}
--   fn-call      {name, args, tick}
--   spawn-event  {family, key, init, tick}
--   despawn-event {family, key, tick}
--   clamp-event  {path, attempted, clamped, tick}
--   watch-fired  {label, kind, path?, value, tick}

local M = {}

local DEFAULT_PORT = 7373
local DEFAULT_HTTP_PORT = 7374

-- ============================================================
-- Embedded browser debug UI (served at GET /)
-- ============================================================

M.HTML_UI = [==========[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>StoryBase Debug</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Courier New',monospace;background:#0d1117;color:#c9d1d9;height:100vh;display:flex;flex-direction:column;font-size:13px}
header{padding:8px 16px;background:#161b22;border-bottom:1px solid #30363d;display:flex;align-items:center;gap:16px;flex-shrink:0}
header h1{font-size:13px;color:#ff7b72;letter-spacing:2px;text-transform:uppercase;font-weight:bold}
.badge{font-size:11px;padding:2px 8px;border-radius:3px;background:#21262d;color:#8b949e}
.badge.ok{background:#1a3a1a;color:#56d364}
.badge.err{background:#3a1a1a;color:#f85149}
.main{flex:1;display:flex;overflow:hidden;min-height:0}
#game-panel{width:42%;min-width:260px;display:flex;flex-direction:column;border-right:1px solid #30363d}
.ptitle{padding:4px 12px;background:#161b22;font-size:10px;color:#8b949e;letter-spacing:1px;text-transform:uppercase;border-bottom:1px solid #30363d;flex-shrink:0}
#transcript{flex:0.6;overflow-y:auto;padding:12px 14px;line-height:1.7;white-space:pre-wrap}
.sb{margin-bottom:8px}
.sb.tt-here{border-left:3px solid #388bfd;padding-left:8px;background:#161b22}
.sb.tt-past{opacity:0.4}
.sl{color:#8b949e;font-size:10px;margin-bottom:4px}
.sn{color:#c9d1d9}
#choices-bar{padding:8px 10px;border-top:1px solid #30363d;display:flex;flex-direction:column;flex-wrap:wrap;align-content:stretch;max-height:280px;gap:5px}
.cb{padding:5px 10px;background:#21262d;border:1px solid #30363d;color:#c9d1d9;cursor:pointer;font-family:inherit;font-size:12px;border-radius:3px;text-align:left}
.cb:hover:not(:disabled){background:#388bfd22;border-color:#388bfd;color:#79c0ff}
.cb:disabled{opacity:0.35;cursor:not-allowed}
#debug-panels{flex:1;display:flex;flex-direction:column;min-width:0;overflow:hidden}
.dp{flex:1;display:flex;flex-direction:column;min-height:70px;border-bottom:1px solid #30363d;overflow:hidden}
.dp:last-child{border-bottom:none}
.dpb{flex:1;overflow-y:auto;padding:3px 0}
.sp{padding:1px 10px;display:flex;gap:6px;font-size:12px}
.sp:hover{background:#161b22}
.spk{color:#8b949e;flex-shrink:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:55%}
.spv{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.spv.n{color:#79c0ff}.spv.b{color:#ff7b72}.spv.s{color:#a5d6ff}.spv.o{color:#56d364}
.me{padding:2px 10px;border-bottom:1px solid #21262d;font-size:11px;line-height:1.5}
.mep{color:#ff7b72}.mea{color:#8b949e}.mem{color:#8b949e;font-size:10px;margin-left:4px}
.tl{padding:8px 12px}
#tslider{width:100%;accent-color:#388bfd;cursor:pointer}
.tlb{display:flex;justify-content:space-between;font-size:10px;color:#8b949e;margin-top:2px}
.we{padding:2px 10px;border-bottom:1px solid #21262d;font-size:11px;line-height:1.5}
.wel{color:#d2a8ff}.wep{color:#ffa657}.wem{color:#8b949e;font-size:10px;margin-left:4px}
</style>
</head>
<body>
<header>
  <h1>StoryBase</h1>
  <span id="cbadge" class="badge err">disconnected</span>
  <span id="mbadge" class="badge">mode: ?</span>
  <span id="tbadge" class="badge">seq: 0</span>
</header>
<div class="main">
  <div id="game-panel">
    <div class="ptitle">Game</div>
    <div id="transcript"></div>
    <div id="choices-bar"></div>
  </div>
  <div id="debug-panels">
    <div class="dp" style="flex:1.5">
      <div class="ptitle">State</div>
      <div class="dpb" id="state-panel"></div>
    </div>
    <div class="dp" style="flex:1.2">
      <div class="ptitle">Mutations</div>
      <div class="dpb" id="mut-panel"></div>
    </div>
    <div class="dp" style="flex:0 0 auto">
      <div class="ptitle">Timeline</div>
      <div class="tl">
        <input type="range" id="tslider" min="0" max="0" value="0">
        <div class="tlb"><span>0</span><span id="tmaxlbl">0</span></div>
      </div>
    </div>
    <div class="dp" style="flex:0.8">
      <div class="ptitle">Watches</div>
      <div class="dpb" id="watch-panel"></div>
    </div>
  </div>
</div>
<script>
var mode='debug',maxTick=0,live=true,_pc=0,_pt=null;
function fv(v){if(v===null||v===undefined)return'null';return JSON.stringify(v);}
function vc(v){var t=typeof v;if(t==='number')return'n';if(t==='boolean')return'b';if(t==='string')return's';return'o';}
async function api(p){
  try{
    var r=await fetch('/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(p)});
    return await r.json();
  }catch(e){return{error:String(e)};}
}
function markTranscript(t){
  var blocks=document.getElementById('transcript').querySelectorAll('.sb');
  if(live){
    blocks.forEach(function(b){b.classList.remove('tt-here','tt-past');});
    return;
  }
  var last=-1;
  for(var i=0;i<blocks.length;i++){
    if(parseInt(blocks[i].getAttribute('data-seq')||'0')<=t)last=i;
  }
  blocks.forEach(function(b,i){
    b.classList.remove('tt-here','tt-past');
    if(i===last)b.classList.add('tt-here');
    else if(i>last)b.classList.add('tt-past');
  });
  if(last>=0)blocks[last].scrollIntoView({block:'nearest'});
}
function renderScene(d){
  if(!d||d.error)return;
  var tr=document.getElementById('transcript');
  var blk=document.createElement('div');blk.className='sb';
  blk.setAttribute('data-seq',maxTick);
  var lbl=document.createElement('div');lbl.className='sl';
  lbl.textContent='['+( d.scene||'?')+']';
  var nar=document.createElement('div');nar.className='sn';
  nar.textContent=(Array.isArray(d.narration)?d.narration.join('\n'):(d.narration||''));
  blk.appendChild(lbl);blk.appendChild(nar);tr.appendChild(blk);
  tr.scrollTop=tr.scrollHeight;
  var bar=document.getElementById('choices-bar');bar.innerHTML='';
  (d.choices||[]).forEach(function(c){
    var btn=document.createElement('button');btn.className='cb';
    btn.textContent=c.idx+'. '+c.label;
    btn.disabled=(mode!=='serve');
    if(mode!=='serve')btn.title='Start with --serve to enable browser play';
    btn.onclick=function(){doChoice(c.idx);};
    bar.appendChild(btn);
  });
}
async function loadScene(){renderScene(await api({cmd:'get-scene'}));}
async function doChoice(n){
  document.querySelectorAll('.cb').forEach(function(b){b.disabled=true;});
  _pc++;if(_pt)clearTimeout(_pt);
  _pt=setTimeout(function(){_pc=0;_pt=null;},2000);
  renderScene(await api({cmd:'do-choice',n:n}));
}
function renderState(m){
  var p=document.getElementById('state-panel');p.innerHTML='';
  Object.keys(m).sort().forEach(function(k){
    var row=document.createElement('div');row.className='sp';
    var ek=document.createElement('span');ek.className='spk';ek.textContent=k;ek.title=k;
    var ev=document.createElement('span');ev.className='spv '+vc(m[k]);ev.textContent=fv(m[k]);ev.title=fv(m[k]);
    row.appendChild(ek);row.appendChild(ev);p.appendChild(row);
  });
}
function patchState(path,val){
  var rows=document.getElementById('state-panel').querySelectorAll('.sp');
  for(var i=0;i<rows.length;i++){
    if(rows[i].querySelector('.spk').textContent===path){
      var ev=rows[i].querySelector('.spv');
      ev.className='spv '+vc(val);ev.textContent=fv(val);ev.title=fv(val);return;
    }
  }
  var row=document.createElement('div');row.className='sp';
  var ek=document.createElement('span');ek.className='spk';ek.textContent=path;ek.title=path;
  var ev=document.createElement('span');ev.className='spv '+vc(val);ev.textContent=fv(val);ev.title=fv(val);
  row.appendChild(ek);row.appendChild(ev);
  document.getElementById('state-panel').appendChild(row);
}
async function loadState(){
  var r=await api({cmd:'get-state',pattern:'*'});
  if(r.state)renderState(r.state);
}
function mutRow(m){
  var row=document.createElement('div');row.className='me';
  row.innerHTML='<span class="mep">'+(m.path||'')+'</span>'
    +'<span class="mea"> '+fv(m.old)+' \u2192 '+fv(m['new'])+'</span>'
    +'<span class="mem"> '+(m.fn||'')+' #'+(m.seq!=null?m.seq:(m.tick||0))+'</span>';
  return row;
}
function addMut(m){
  var p=document.getElementById('mut-panel');
  p.insertBefore(mutRow(m),p.firstChild);
  if(p.children.length>200)p.removeChild(p.lastChild);
}
function renderMuts(entries){
  var p=document.getElementById('mut-panel');p.innerHTML='';
  for(var i=(entries.length-1);i>=0;i--)p.appendChild(mutRow(entries[i]));
}
async function loadMuts(){
  var r=await api({cmd:'get-log'});
  if(r.entries)renderMuts(r.entries);
}
var slider=document.getElementById('tslider');
var tmaxlbl=document.getElementById('tmaxlbl');
slider.oninput=async function(){
  var t=parseInt(this.value);live=(t===maxTick);
  document.getElementById('tbadge').textContent='seq: '+t;
  if(!live){
    document.querySelectorAll('.cb').forEach(function(b){b.disabled=true;});
    var r=await api({cmd:'time-travel',seq:t});
    if(r.snapshot)renderState(r.snapshot);
    if(r.entries)renderMuts(r.entries);
    if(r.watches)renderWatches(r.watches);
    markTranscript(t);
  }else{
    await loadState();
    await loadMuts();
    await loadWatches();
    markTranscript(t);
    document.querySelectorAll('.cb').forEach(function(b){b.disabled=(mode!=='serve');});
  }
};
function setTick(t){
  if(t>maxTick){
    maxTick=t;slider.max=maxTick;tmaxlbl.textContent=String(maxTick);
    if(live)slider.value=maxTick;
  }
  document.getElementById('tbadge').textContent='seq: '+(live?maxTick:parseInt(slider.value));
}
function watchHtml(w){
  var lbl=String(w.label||'');
  return '<span class="wel">['+lbl+']</span> '
    +'<span class="wep">'+(w.path||'')+'</span>'
    +' = '+fv(w.value)
    +'<span class="wem"> #'+(w.seq!=null?w.seq:(w.tick||0))+'</span>';
}
function setWatch(w){
  var p=document.getElementById('watch-panel');
  var lbl=String(w.label||'');
  var html=watchHtml(w);
  var rows=p.querySelectorAll('.we');
  for(var i=0;i<rows.length;i++){
    if(rows[i].getAttribute('data-wl')===lbl){rows[i].innerHTML=html;return;}
  }
  var row=document.createElement('div');row.className='we';
  row.setAttribute('data-wl',lbl);row.innerHTML=html;
  p.appendChild(row);
}
function renderWatches(watches){
  var p=document.getElementById('watch-panel');p.innerHTML='';
  (watches||[]).forEach(function(w){
    var row=document.createElement('div');row.className='we';
    row.setAttribute('data-wl',String(w.label||''));
    row.innerHTML=watchHtml(w);
    p.appendChild(row);
  });
}
async function loadWatches(){
  var r=await api({cmd:'get-watches'});
  if(r.watches)renderWatches(r.watches);
}
function connectSSE(){
  var es=new EventSource('/events');
  es.onopen=function(){
    document.getElementById('cbadge').textContent='connected';
    document.getElementById('cbadge').className='badge ok';
  };
  es.onmessage=function(e){
    try{
      var ev=JSON.parse(e.data),d=ev.data||{};
      if(ev.event==='mutation'){
        if(live)addMut(d);
        if(live&&d.path!=null)patchState(d.path,d['new']);
        if(d.seq!=null)setTick(d.seq);
      }else if(ev.event==='scene-change'){
        if(_pc>0){_pc--;if(_pt){clearTimeout(_pt);_pt=null;}}else if(live){loadScene();}
      }else if(ev.event==='watch-fired'){
        if(live)setWatch(d);
      }
    }catch(_){}
  };
  es.onerror=function(){
    document.getElementById('cbadge').textContent='disconnected';
    document.getElementById('cbadge').className='badge err';
    es.close();setTimeout(connectSSE,2000);
  };
}
async function init(){
  connectSSE();
  var mr=await api({cmd:'get-mode'});
  mode=(mr&&mr.mode)||'debug';
  document.getElementById('mbadge').textContent='mode: '+mode;
  var tr=await api({cmd:'get-tick'});
  if(tr&&tr.seq!=null)setTick(tr.seq);
  await loadState();
  await loadWatches();
  await loadScene();
}
init();
</script>
</body>
</html>
]==========]

-- ============================================================
-- Helpers
-- ============================================================

--- Pattern match: does `path` match `pattern`?
---
--- Supported wildcards (idea.md §4.3):
---   *      — any single path segment (no slashes)
---   **     — any sequence of segments (including slashes)
---   (a|b)  — alternation: matches if any branch matches (recursively expanded)
---
---@param pattern string  e.g. "player/*", "npcs/*/health", "player/**", "player/(health|mana)"
---@param path    string  e.g. "player/health"
---@return boolean
local function path_matches(pattern, path)
  if pattern == "*"  then return true end
  if pattern == path then return true end

  -- Expand (a|b|c) alternation groups recursively
  local alt_s, alt_e = pattern:find("%((.-)%)")
  if alt_s then
    local before    = pattern:sub(1, alt_s - 1)
    local alt_inner = pattern:sub(alt_s + 1, alt_e - 1)
    local after     = pattern:sub(alt_e + 1)
    for branch in alt_inner:gmatch("[^|]+") do
      if path_matches(before .. branch .. after, path) then return true end
    end
    return false
  end

  -- Convert to a Lua pattern:
  --   1. Escape Lua magic chars (not *)
  --   2. Replace ** with a NUL placeholder so it is not touched by the * step
  --   3. Replace remaining * with [^/]+ (single segment)
  --   4. Replace placeholder with .* (any segments)
  local lp = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  lp = lp:gsub("%*%*", "\0")       -- placeholder for **
  lp = lp:gsub("%*", "[^/]+")      -- * = one segment (no slashes)
  lp = lp:gsub("\0", ".*")         -- ** = any segments (including slashes)
  return path:match("^" .. lp .. "$") ~= nil
end

--- Return true when `pattern` contains any wildcard character that requires
--- iterating all cache keys rather than doing an exact lookup.
local function is_pattern(s)
  return s:find("%*") ~= nil or s:find("%(") ~= nil
end

-- ============================================================
-- Debug server constructor
-- ============================================================

--- Create a new debug server instance.
---@param engine  table    Engine instance
---@param opts    table?   {port, mode} — mode: "hook" | "tcp" (default "hook")
---@return table
function M.new(engine, opts)
  opts = opts or {}

  local srv = {
    _engine       = engine,
    _port         = opts.port or DEFAULT_PORT,
    _mode         = opts.mode or "hook",
    _running      = false,
    _clients      = {},          -- TCP clients (when in tcp mode)
    _breakpoints  = {},          -- {id → condition_fn}
    _bp_counter   = 0,
    _watches      = {},          -- {kind, path?, condition?, label}
    _handlers     = {},          -- {event_name → [fn, ...]}
    _tcp_socket   = nil,
    -- HTTP server fields (populated by start_http)
    _http_socket  = nil,
    _http_clients = {},          -- active HTTP connections being parsed
    _sse_clients  = {},          -- open SSE connections (sockets)
    _serve_mode   = false,       -- true when started with --serve
  }

  -- ── Event delivery ────────────────────────────────────────

  --- Register a Lua callback to receive a given event type.
  ---@param event_name string
  ---@param fn         function  fn(payload)
  function srv:on(event_name, fn)
    if not self._handlers[event_name] then
      self._handlers[event_name] = {}
    end
    table.insert(self._handlers[event_name], fn)
  end

  --- Emit an event to all registered handlers and connected TCP clients.
  ---@param event_name string
  ---@param payload    table
  function srv:emit(event_name, payload)
    if not self._running then return end
    local hs = self._handlers[event_name] or {}
    for _, fn in ipairs(hs) do
      pcall(fn, payload)
    end
    -- TCP broadcast (if in tcp mode and clients connected)
    if self._mode == "tcp" and #self._clients > 0 then
      local json = M.encode_json({ event = event_name, data = payload })
      self:_broadcast(json .. "\n")
    end
    -- SSE broadcast to browser clients
    if self._sse_clients and #self._sse_clients > 0 then
      self:_sse_push(event_name, payload)
    end
  end

  -- ── Watch evaluation ───────────────────────────────────────

  --- Register a watch-path declaration.
  ---@param path  string
  ---@param label string
  function srv:register_watch(path, label)
    self._watches[#self._watches + 1] = {
      kind  = "path",
      path  = path,
      label = label,
    }
  end

  --- Register a watch-when declaration (condition as compiled AST expr).
  ---@param cond_expr  table   Compiled AST expression
  ---@param label      string
  function srv:register_watch_when(cond_expr, label)
    self._watches[#self._watches + 1] = {
      kind      = "cond",
      cond_expr = cond_expr,
      label     = label,
      _last     = nil,   -- last evaluated result (for edge detection)
    }
  end

  --- Evaluate all watches against the current engine state.
  --- Fires `watch-fired` events for triggered watches.
  function srv:check_watches()
    if not self._running then return end
    local eng = self._engine
    if not eng then return end

    local eval_mod = require("runtime.eval")
    local tick_val = eng._state and eng._state:get("world/tick") or 0

    for _, w in ipairs(self._watches) do
      if w.kind == "path" then
        if is_pattern(w.path) then
          -- Pattern watch: iterate all cache keys and fire for each match
          if eng._state then
            for cache_path, val in pairs(eng._state._cache) do
              if val ~= nil and path_matches(w.path, cache_path) then
                self:emit("watch-fired", {
                  label = w.label, kind = "path", path = cache_path,
                  value = val, tick = tick_val,
                })
              end
            end
          end
        else
          local val = eng._state and eng._state:get(w.path)
          if val ~= nil then
            self:emit("watch-fired", {
              label = w.label, kind = "path", path = w.path, value = val, tick = tick_val
            })
          end
        end

      elseif w.kind == "cond" then
        local ctx = eval_mod.new_ctx(eng._state, eng._fns, "watch-when")
        local ok, result = pcall(eval_mod.eval_expr, w.cond_expr, ctx)
        local cur = ok and result or false
        -- Fire on positive edge (false→true)
        if cur and not w._last then
          self:emit("watch-fired", {
            label = w.label, kind = "cond", value = true, tick = tick_val
          })
        end
        w._last = cur
      end
    end
  end

  -- ── Command handlers ───────────────────────────────────────

  --- Handle an incoming command.
  ---@param cmd     string  Command name
  ---@param payload table   Command payload
  ---@return table          Response payload
  function srv:handle_command(cmd, payload)
    payload = payload or {}
    local eng = self._engine

    if cmd == "get-state" then
      local pattern = payload.pattern or "*"
      local result  = {}
      if eng and eng._state then
        for path, val in pairs(eng._state._cache) do
          if path_matches(pattern, path) then
            result[path] = val
          end
        end
      end
      return { state = result }

    elseif cmd == "eval" then
      local expr_src = payload.expr
      if not expr_src then return { error = "missing 'expr'" } end
      if not eng then return { error = "no engine" } end

      -- Compile the expression
      local compiler_mod = require("compiler.compiler")
      local ok, gt = pcall(compiler_mod.compile,
        "module _eval version: 1.0 engine-config: entry-scene: _s\n"
        .. "scene _s:\n  * Go\n    -> _s\n"
        .. "fn _expr:\n  " .. expr_src)
      if not ok or not gt then
        return { error = "compile error: " .. tostring(gt) }
      end
      local fn_def = gt.fns and gt.fns["_expr"]
      if not fn_def then return { error = "expression failed to compile" } end

      local eval_mod = require("runtime.eval")
      local ctx = eval_mod.new_ctx(eng._state, eng._fns, "eval")
      local ok2, val = pcall(eval_mod.eval_stmts, fn_def.body, ctx)
      if not ok2 then return { error = tostring(val) } end
      return { value = ctx.retval }

    elseif cmd == "get-log" then
      if not eng then return { entries = {} } end
      local from = payload.from or 1
      local to   = payload.to
      local all  = eng._log:entries()
      local slice = {}
      for i = from, (to or #all) do
        if all[i] then slice[#slice + 1] = all[i] end
      end
      return { entries = slice }

    elseif cmd == "time-travel" then
      local seq = payload.seq
      if not eng or not seq then return { error = "missing 'seq'" } end

      -- Build a replay of the log up to the requested seq number
      local state_mod = require("runtime.state")
      local log_mod   = require("runtime.log")
      local snap_log  = log_mod.new()
      local snap_state = state_mod.new(
        eng._game and eng._game.schema or {}, snap_log)
      snap_state:init_defaults()

      -- Replay all entries with seq ≤ requested seq
      for _, e in ipairs(eng._log:entries()) do
        if e.seq <= seq then
          snap_state._cache[e.path] = e["new"]
        else
          break
        end
      end

      -- Return a frozen snapshot (table of path→value)
      local frozen = {}
      for k, v in pairs(snap_state._cache) do frozen[k] = v end

      -- Log entries up to this seq (for the mutations panel)
      local entries_snap = {}
      for _, e in ipairs(eng._log:entries()) do
        if e.seq <= seq then entries_snap[#entries_snap+1] = e else break end
      end

      -- Evaluate watches against the snapshot state
      local eval_mod = require("runtime.eval")
      local watches_snap = {}
      for _, w in ipairs(self._watches) do
        if w.kind == "path" then
          if is_pattern(w.path) then
            for cache_path, val in pairs(snap_state._cache) do
              if val ~= nil and path_matches(w.path, cache_path) then
                watches_snap[#watches_snap+1] = { label = w.label, kind = "path",
                  path = cache_path, value = val }
              end
            end
          else
            watches_snap[#watches_snap+1] = { label = w.label, kind = "path",
              path = w.path, value = snap_state._cache[w.path] }
          end
        elseif w.kind == "cond" then
          local wctx = eval_mod.new_ctx(snap_state, eng._fns, "watch-when")
          local ok, cur = pcall(eval_mod.eval_expr, w.cond_expr, wctx)
          watches_snap[#watches_snap+1] = { label = w.label, kind = "cond",
            value = (ok and cur or false) }
        end
      end

      return { snapshot = frozen, seq = seq,
               entries = entries_snap, watches = watches_snap }

    elseif cmd == "set-breakpoint" then
      local cond = payload.condition
      if not cond then return { error = "missing 'condition'" } end
      self._bp_counter = self._bp_counter + 1
      local id = self._bp_counter
      self._breakpoints[id] = cond
      return { id = id }

    elseif cmd == "clear-breakpoint" then
      local id = payload.id
      self._breakpoints[id] = nil
      return { ok = true }

    elseif cmd == "reload" then
      local src = payload.src
      if not src then return { error = "missing 'src'" } end
      if not eng then return { error = "no engine" } end

      local compiler_mod = require("compiler.compiler")
      local ok, new_gt = pcall(compiler_mod.compile, src)
      if not ok or not new_gt then
        return { ok = false, error = tostring(new_gt) }
      end

      -- Schema migration: apply field additions, removals, type changes
      -- transactionally (collect all changes, then apply or error).
      local old_schema = eng._game and eng._game.schema or {}
      local new_schema = new_gt.schema or {}
      local changes = {}
      local schema_errors = {}

      -- Build old and new state path info
      local function build_state_map(schema)
        local m = {}
        for _, s in ipairs(schema.states or {}) do
          if s.kind == "scalar" then
            m[s.path] = { kind = "scalar", type_desc = s.type_desc, default = s.default }
          elseif s.kind == "record" then
            for _, f in ipairs(s.fields or {}) do
              if f.name then
                m[s.path .. "/" .. f.name] = { kind = "field", type_desc = f.type_desc, default = f.default }
              end
            end
          elseif s.kind == "family" then
            -- Store family type for per-member field checks
            m["__family__" .. s.family] = { kind = "family", type_desc = s.type_desc, fields = s.fields or {} }
          end
        end
        return m
      end

      local old_map = build_state_map(old_schema)
      local new_map = build_state_map(new_schema)

      local function resolve_default(d)
        if not d then return nil end
        if d.tag == "int" or d.tag == "float" or d.tag == "bool" or d.tag == "string" then
          return d.value
        elseif d.tag == "symbol" then return d.name
        elseif d.tag == "empty_set" or d.tag == "empty_list" or d.tag == "empty_map" then
          return {}
        end
        return nil
      end

      -- Build name → type_def lookup from new schema types
      local new_type_defs = {}
      for _, t in ipairs(new_schema.types or {}) do
        if t.name then new_type_defs[t.name] = t end
      end

      -- Resolve a type descriptor (follow named references)
      local function resolve_td(td)
        if not td then return nil end
        if td.tag == "named" then return new_type_defs[td.name] end
        return td
      end

      -- Validate current values against new schema
      local cache = eng._state and eng._state._cache or {}
      for path, cur_val in pairs(cache) do
        local ni = new_map[path]
        if ni then
          local td = resolve_td(ni.type_desc)
          -- Range narrowing: Int type range check
          if td and td.tag == "int" and type(cur_val) == "number" then
            if (td.min and cur_val < td.min) or (td.max and cur_val > td.max) then
              schema_errors[#schema_errors+1] = string.format(
                "path %s value %s out of new range [%s, %s]",
                path, tostring(cur_val), tostring(td.min), tostring(td.max))
            end
          end
          -- Enum validation: named enum check
          if td and td.kind == "enum" and type(cur_val) == "string" then
            local valid = false
            for _, v in ipairs(td.values or {}) do
              if v == cur_val then valid = true; break end
            end
            if not valid then
              schema_errors[#schema_errors+1] = string.format(
                "path %s value '%s' not valid in new enum", path, cur_val)
            end
          end
        end
      end

      if #schema_errors > 0 then
        return { ok = false, error = table.concat(schema_errors, "; ") }
      end

      -- Build list of transactional cache changes
      -- New fields: initialise with default
      for path, ni in pairs(new_map) do
        if ni.kind ~= "family" and not old_map[path] then
          local def_val = resolve_default(ni.default)
          if def_val ~= nil then
            changes[#changes+1] = { op = "set", path = path, value = def_val }
          end
        end
      end
      -- New family fields: find all existing member instances and init
      for fname, ni in pairs(new_map) do
        if ni.kind == "family" then
          local old_fi = old_map[fname]
          local old_fields = {}
          for _, f in ipairs(old_fi and old_fi.fields or {}) do
            old_fields[f.name] = true
          end
          for _, f in ipairs(ni.fields or {}) do
            if f.name and not old_fields[f.name] then
              -- New field for this family; apply to all current instances
              local family = fname:sub(#"__family__" + 1)
              local prefix = family .. "/"
              local seen_keys = {}
              for p in pairs(cache) do
                if p:sub(1, #prefix) == prefix then
                  local rest = p:sub(#prefix + 1)
                  local key  = rest:match("^([^/]+)")
                  if key and not seen_keys[key] then
                    seen_keys[key] = true
                    local field_path = family .. "/" .. key .. "/" .. f.name
                    if cache[field_path] == nil then
                      local def_val = resolve_default(f.default)
                      if def_val ~= nil then
                        changes[#changes+1] = { op = "set", path = field_path, value = def_val }
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      -- Removed fields: drop silently
      for path, _ in pairs(old_map) do
        if old_map[path].kind ~= "family" and not new_map[path] then
          if cache[path] ~= nil then
            changes[#changes+1] = { op = "drop", path = path }
          end
        end
      end

      -- Apply all changes atomically
      for _, ch in ipairs(changes) do
        if ch.op == "set" then
          eng._state._cache[ch.path] = ch.value
        elseif ch.op == "drop" then
          eng._state._cache[ch.path] = nil
        end
      end

      -- Hot-reload: update fns and scenes in place, preserve state
      eng._fns   = new_gt.fns   or {}
      eng._scenes = new_gt.scenes or {}
      eng._game  = new_gt

      local tick = eng._state and eng._state._time and eng._state._time.tick or 0
      local outcome = #changes > 0 and "migrated" or "unchanged"
      -- Emit reload event
      srv:emit("reload", { file = payload.file, outcome = outcome,
                            changes = #changes, tick = tick })
      return { ok = true, outcome = outcome, changes = #changes }

    elseif cmd == "get-schema" then
      if not eng or not eng._game then
        return { error = "no engine or game not loaded" }
      end
      local g = eng._game

      -- Types
      local types = {}
      for _, t in ipairs(g.schema and g.schema.types or {}) do
        local entry = { kind = t.kind, name = t.name, doc = t.doc }
        if t.values   then entry.values   = t.values   end
        if t.fields   then entry.fields   = t.fields   end
        if t.branches then entry.branches = t.branches end
        types[#types+1] = entry
      end

      -- States
      local states = {}
      for _, s in ipairs(g.schema and g.schema.states or {}) do
        local entry = {
          path      = s.path,
          kind      = s.kind,
          type_desc = s.type_desc,
          default   = s.default,
          doc       = s.doc,
        }
        if s.fields then entry.fields = s.fields end
        states[#states+1] = entry
      end

      -- Relations
      local relations = {}
      for _, r in ipairs(g.schema and g.schema.relations or {}) do
        relations[#relations+1] = {
          name         = r.name,
          from_type    = r.from_type,
          to_type_desc = r.to_type_desc,
          doc          = r.doc,
        }
      end

      -- Fns
      local fns = {}
      for name, f in pairs(g.fns or {}) do
        fns[#fns+1] = {
          name           = name,
          params         = f.params,
          is_transaction = f.is_transaction,
          uses_bounded   = f.uses_bounded,
          doc            = f.doc,
        }
      end

      -- Scenes
      local scenes = {}
      for name, sc in pairs(g.scenes or {}) do
        scenes[#scenes+1] = { name = name, doc = sc.doc }
      end

      -- Actors
      local actors = {}
      for name, a in pairs(g.actors or {}) do
        actors[#actors+1] = {
          name       = name,
          state_path = a.state_path,
          doc        = a.doc,
        }
      end

      -- Schedules
      local schedules = {}
      for name, sc in pairs(g.schedules or {}) do
        schedules[#schedules+1] = { name = name, doc = sc.doc }
      end

      -- Bounded
      local bounded = {}
      for name, b in pairs(g.bounded or {}) do
        bounded[#bounded+1] = {
          name     = name,
          returns  = b.returns,
          reads    = b.reads,
          lua_name = b.lua,
          doc      = b.doc,
        }
      end

      return {
        schema_version = g.schema and g.schema.version,
        engine_config  = g.schema and g.schema.engine_config,
        types          = types,
        states        = states,
        relations     = relations,
        fns           = fns,
        scenes        = scenes,
        actors        = actors,
        schedules     = schedules,
        bounded       = bounded,
      }

    elseif cmd == "get-scene" then
      if not eng then return { error = "no engine" } end
      local scene_name = eng:current_scene()
      if not scene_name then return { error = "no current scene" } end
      local narration, choices, nav_signal = eng:render_scene(scene_name)
      -- Follow unconditional nav signal (same as eng:step())
      if nav_signal then
        if nav_signal.type == "goto" then
          eng:goto_scene(nav_signal.target)
        elseif nav_signal.type == "enter" then
          eng:enter_scene(nav_signal.target)
        elseif nav_signal.type == "exit" then
          eng:exit_scene()
        end
        scene_name = eng:current_scene()
        if scene_name then
          narration, choices = eng:render_scene(scene_name)
        end
      end
      local choice_list = {}
      for i, c in ipairs(choices or {}) do
        choice_list[i] = { idx = i, label = c.label or "" }
      end
      return { scene = scene_name, narration = narration or {}, choices = choice_list }

    elseif cmd == "do-choice" then
      local n = tonumber(payload.n)
      if not n then return { error = "missing 'n'" } end
      if not srv._serve_mode then
        return { error = "not in serve mode; start with --serve to enable browser play" }
      end
      if not eng then return { error = "no engine" } end
      local scene_name = eng:current_scene()
      if not scene_name then return { error = "no current scene" } end
      local ok, signal = pcall(eng.do_choice, eng, scene_name, n)
      if not ok then return { error = tostring(signal) } end
      pcall(eng.post_action, eng)
      if signal then
        if signal.type == "goto" then
          pcall(eng.goto_scene, eng, signal.target)
        elseif signal.type == "enter" then
          pcall(eng.enter_scene, eng, signal.target)
        elseif signal.type == "exit" then
          pcall(eng.exit_scene, eng)
        end
      end
      -- Return updated scene (same as get-scene)
      scene_name = eng:current_scene()
      if not scene_name then
        return { ok = true, scene = nil, narration = {}, choices = {} }
      end
      local narration, choices = eng:render_scene(scene_name)
      local choice_list = {}
      for i, c in ipairs(choices or {}) do
        choice_list[i] = { idx = i, label = c.label or "" }
      end
      return { ok = true, scene = scene_name, narration = narration or {}, choices = choice_list }

    elseif cmd == "get-tick" then
      local seq = 0
      if eng and eng._log then
        seq = eng._log:seq()
      end
      return { seq = seq }

    elseif cmd == "get-mode" then
      return { mode = srv._serve_mode and "serve" or "debug" }

    elseif cmd == "get-watches" then
      local eval_mod = require("runtime.eval")
      local tick_val = eng and eng._state and eng._state:get("world/tick") or 0
      local result = {}
      for _, w in ipairs(self._watches) do
        if w.kind == "path" then
          if is_pattern(w.path) then
            if eng and eng._state then
              for cache_path, val in pairs(eng._state._cache) do
                if val ~= nil and path_matches(w.path, cache_path) then
                  result[#result+1] = { label = w.label, kind = "path",
                    path = cache_path, value = val, tick = tick_val }
                end
              end
            end
          else
            local val = eng and eng._state and eng._state:get(w.path)
            result[#result+1] = { label = w.label, kind = "path",
              path = w.path, value = val, tick = tick_val }
          end
        elseif w.kind == "cond" then
          if eng and eng._state then
            local ctx = eval_mod.new_ctx(eng._state, eng._fns, "watch-when")
            local ok, cur = pcall(eval_mod.eval_expr, w.cond_expr, ctx)
            result[#result+1] = { label = w.label, kind = "cond",
              value = (ok and cur or false), tick = tick_val }
          end
        end
      end
      return { watches = result }

    else
      return { error = "unknown command: " .. tostring(cmd) }
    end
  end

  -- ── Server lifecycle ───────────────────────────────────────

  --- Start the debug server.
  function srv:start()
    self._running = true
    if self._mode == "tcp" then
      local ok, socket = pcall(require, "socket")
      if ok and socket then
        local s, err = socket.tcp()
        if not s then
          io.stderr:write("storybase debug: cannot create socket: "
                          .. tostring(err) .. "\n")
          self._mode = "hook"; return
        end
        s:setoption("reuseaddr", true)
        local bound, berr = s:bind("*", self._port)
        if not bound then
          io.stderr:write("storybase debug: cannot bind port "
                          .. self._port .. ": " .. tostring(berr) .. "\n")
          s:close(); self._mode = "hook"; return
        end
        s:listen(8)
        s:settimeout(0)
        self._tcp_socket = s
        io.stderr:write("storybase debug: listening on port "
                        .. self._port .. "\n")
      else
        io.stderr:write("storybase debug: LuaSocket not available; TCP disabled\n")
        self._mode = "hook"
      end
    end
  end

  --- Stop the debug server (TCP + HTTP).
  function srv:stop()
    self._running = false
    for _, c in ipairs(self._clients) do
      pcall(function() c:close() end)
    end
    self._clients = {}
    if self._tcp_socket then
      pcall(function() self._tcp_socket:close() end)
      self._tcp_socket = nil
    end
    -- Also stop HTTP server if running
    self:stop_http()
  end

  -- ── HTTP server (browser debug UI) ──────────────────────────

  --- Start the HTTP server for the browser debug UI.
  ---@param port integer  HTTP port (default: DEFAULT_HTTP_PORT)
  function srv:start_http(port)
    port = port or DEFAULT_HTTP_PORT
    self._http_port = port
    local ok_s, socket = pcall(require, "socket")
    if not ok_s or not socket then
      io.stderr:write("storybase debug-ui: LuaSocket not available\n")
      return
    end
    local s, err = socket.tcp()
    if not s then
      io.stderr:write("storybase debug-ui: cannot create socket: " .. tostring(err) .. "\n")
      return
    end
    s:setoption("reuseaddr", true)
    pcall(function() s:setoption("reuseport", true) end)  -- best-effort; not all platforms
    local bound, berr = s:bind("*", port)
    if not bound then
      io.stderr:write("storybase debug-ui: cannot bind port " .. port
                      .. ": " .. tostring(berr) .. "\n")
      s:close()
      return
    end
    local listened, lerr = s:listen(32)
    if not listened then
      io.stderr:write("storybase debug-ui: cannot listen port " .. port
                      .. ": " .. tostring(lerr) .. "\n")
      s:close()
      return
    end
    s:settimeout(0)
    self._http_socket  = s
    self._http_clients = {}
    self._sse_clients  = {}
  end

  --- Stop the HTTP server and close all HTTP/SSE clients.
  function srv:stop_http()
    for _, c in ipairs(self._http_clients or {}) do
      pcall(function() c.sock:close() end)
    end
    for _, sock in ipairs(self._sse_clients or {}) do
      pcall(function() sock:close() end)
    end
    self._http_clients = {}
    self._sse_clients  = {}
    if self._http_socket then
      pcall(function() self._http_socket:close() end)
      self._http_socket = nil
    end
  end

  --- Push a Server-Sent Event to all connected browser SSE clients.
  ---@param event_name string
  ---@param payload    table
  function srv:_sse_push(event_name, payload)
    if not self._sse_clients or #self._sse_clients == 0 then return end
    local msg = "data: " .. M.encode_json({ event = event_name, data = payload }) .. "\n\n"
    local live = {}
    for _, sock in ipairs(self._sse_clients) do
      local ok = pcall(function() sock:send(msg) end)
      if ok then live[#live + 1] = sock end
    end
    self._sse_clients = live
  end

  --- Write a minimal HTTP/1.1 response and close the socket.
  --- Uses a blocking timeout for the send so large bodies (e.g. HTML UI) are
  --- delivered in full even when the socket was opened non-blocking.
  ---@param sock       userdata
  ---@param status     string    e.g. "200 OK"
  ---@param ctype      string    Content-Type value
  ---@param body       string
  ---@param extra_hdrs table?    list of extra "Header: Value" strings
  function srv:_http_response(sock, status, ctype, body, extra_hdrs)
    local parts = {
      "HTTP/1.1 " .. status,
      "Content-Type: "   .. ctype,
      "Content-Length: " .. #body,
      "Access-Control-Allow-Origin: *",
      "Cache-Control: no-cache",
      "Connection: close",
    }
    if extra_hdrs then
      for _, h in ipairs(extra_hdrs) do parts[#parts + 1] = h end
    end
    local response = table.concat(parts, "\r\n") .. "\r\n\r\n" .. body
    -- Switch to blocking send so the full response is delivered before close.
    pcall(function() sock:settimeout(5) end)
    pcall(function() sock:send(response) end)
    pcall(function() sock:close() end)
  end

  --- Parse the HTTP request line and header fields from a client's accumulated lines.
  local function parse_http_client(c)
    local first = c.lines[1] or ""
    c.method, c.path = first:match("^(%u+)%s+([^%s]+)%s+HTTP")
    if not c.method then
      -- HTTP/1.0 or malformed: try without version
      c.method, c.path = first:match("^(%u+)%s+([^%s]+)")
    end
    c.method = c.method or "GET"
    c.path   = (c.path or "/"):match("^([^?#]+)") or "/"  -- strip query/fragment
    c.req_headers = {}
    for i = 2, #c.lines do
      local k, v = c.lines[i]:match("^([^:]+):%s*(.+)$")
      if k then
        c.req_headers[k:lower():gsub("%s", "")] = v
      end
    end
  end

  --- Dispatch an HTTP request.  Returns true to keep client in _http_clients (body pending).
  function srv:_dispatch_http(c)
    parse_http_client(c)
    local method = c.method
    local path   = c.path

    if method == "OPTIONS" then
      self:_http_response(c.sock, "200 OK", "text/plain", "", {
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
      })
      return false

    elseif method == "GET" and path == "/" then
      self:_http_response(c.sock, "200 OK", "text/html; charset=utf-8", M.HTML_UI)
      return false

    elseif method == "GET" and path == "/events" then
      -- Server-Sent Events: send headers (blocking), keep socket open in _sse_clients
      local hdr = "HTTP/1.1 200 OK\r\n"
        .. "Content-Type: text/event-stream\r\n"
        .. "Cache-Control: no-cache\r\n"
        .. "Access-Control-Allow-Origin: *\r\n"
        .. "Connection: keep-alive\r\n"
        .. "\r\n"
      pcall(function() c.sock:settimeout(5) end)
      local ok = pcall(function() c.sock:send(hdr) end)
      -- Restore non-blocking for subsequent event pushes
      pcall(function() c.sock:settimeout(0) end)
      if ok then
        self._sse_clients[#self._sse_clients + 1] = c.sock
      else
        pcall(function() c.sock:close() end)
      end
      return false  -- socket moved to _sse_clients; drop from _http_clients

    elseif method == "POST" and (path == "/command" or path == "/cmd") then
      local cl = tonumber(c.req_headers["content-length"]) or 0
      if cl > 0 then
        c.state    = "body"
        c.body     = ""
        c.body_rem = cl
        return true  -- keep in _http_clients to accumulate body
      else
        return self:_handle_post(c)
      end

    else
      self:_http_response(c.sock, "404 Not Found", "text/plain", "Not Found")
      return false
    end
  end

  --- Handle a completed HTTP POST /command request.  Returns false (always done).
  function srv:_handle_post(c)
    local ok, payload = pcall(M.decode_json, c.body or "{}")
    local resp
    if ok and type(payload) == "table" then
      local cmd_name = payload.cmd
      payload.cmd = nil
      resp = self:handle_command(tostring(cmd_name or ""), payload)
    else
      resp = { error = "invalid JSON body" }
    end
    self:_http_response(c.sock, "200 OK", "application/json", M.encode_json(resp))
    return false
  end

  --- Non-blocking poll of the HTTP server: accept new connections and advance
  --- the per-client state machine (headers → body → dispatch → done).
  function srv:poll_http()
    if not self._http_socket then return end

    -- Accept new TCP connections from the HTTP listener
    local client = self._http_socket:accept()
    while client do
      client:settimeout(0)
      self._http_clients[#self._http_clients + 1] = {
        sock      = client,
        state     = "headers",
        lines     = {},
        method    = nil,
        path      = nil,
        req_headers = {},
        body      = "",
        body_rem  = 0,
      }
      client = self._http_socket:accept()
    end

    -- Advance each client's state machine
    local live = {}
    for _, c in ipairs(self._http_clients) do
      local keep = false

      if c.state == "headers" then
        local line, err = c.sock:receive("*l")
        if line then
          line = line:gsub("\r$", "")  -- strip trailing CR
          if line == "" then
            -- Blank line signals end of HTTP headers
            keep = self:_dispatch_http(c)
          else
            c.lines[#c.lines + 1] = line
            keep = true
          end
        elseif err == "timeout" then
          keep = true  -- no data yet; wait for next poll
        end
        -- err == "closed" or other → drop client (keep = false)

      elseif c.state == "body" then
        -- Accumulate body bytes (handles partial reads from non-blocking socket)
        local data, err, partial = c.sock:receive(c.body_rem)
        local chunk = data or partial or ""
        if #chunk > 0 then
          c.body     = c.body .. chunk
          c.body_rem = c.body_rem - #chunk
        end
        if data or c.body_rem <= 0 then
          keep = self:_handle_post(c)
        elseif err == "timeout" then
          keep = true  -- still waiting for rest of body
        end
        -- else: closed → drop
      end

      if keep then live[#live + 1] = c end
    end
    self._http_clients = live
  end

  --- Broadcast a message to all connected TCP clients.
  ---@param msg string
  function srv:_broadcast(msg)
    local live = {}
    for _, c in ipairs(self._clients) do
      local ok = pcall(function() c:send(msg) end)
      if ok then live[#live + 1] = c end
    end
    self._clients = live
  end

  --- Accept one pending TCP connection (non-blocking poll).
  --- Reads pending lines from all clients and dispatches commands.
  function srv:poll()
    if not self._running or not self._tcp_socket then return end
    -- Accept new clients (non-blocking)
    local client = self._tcp_socket:accept()
    while client do
      client:settimeout(0)
      self._clients[#self._clients + 1] = client
      client = self._tcp_socket:accept()
    end
    -- Read lines from existing clients
    local live = {}
    for _, c in ipairs(self._clients) do
      local line, err = c:receive("*l")
      if line then
        local ok_dec, payload = pcall(M.decode_json, line)
        if ok_dec and type(payload) == "table" then
          local cmd = payload.cmd
          payload.cmd = nil  -- remove cmd from payload before passing
          local resp = self:handle_command(tostring(cmd), payload)
          pcall(function() c:send(M.encode_json(resp) .. "\n") end)
        end
        live[#live + 1] = c
      elseif err == "timeout" then
        live[#live + 1] = c  -- still alive, just no data
      end
      -- err == "closed" or other → drop client
    end
    self._clients = live
  end

  return srv
end

-- ============================================================
-- Minimal JSON encoder (no external dependency)
-- ============================================================

--- Encode a Lua value as a JSON string.
--- Handles nil, boolean, number, string, array table, object table.
---@param v any
---@return string
function M.encode_json(v)
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    if v ~= v then return "null" end  -- NaN
    return tostring(v)
  elseif t == "string" then
    -- Escape special characters
    local s = v:gsub('\\', '\\\\')
               :gsub('"',  '\\"')
               :gsub('\n', '\\n')
               :gsub('\r', '\\r')
               :gsub('\t', '\\t')
    return '"' .. s .. '"'
  elseif t == "table" then
    -- Detect array vs object: array if all keys are consecutive integers from 1
    local is_array = true
    local n = 0
    for k in pairs(v) do
      n = n + 1
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        is_array = false; break
      end
    end
    if is_array and n == #v then
      local parts = {}
      for _, item in ipairs(v) do
        parts[#parts + 1] = M.encode_json(item)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = M.encode_json(tostring(k)) .. ":" .. M.encode_json(val)
      end
      table.sort(parts)  -- stable output
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    return '"' .. tostring(v) .. '"'
  end
end

-- ============================================================
-- Minimal JSON decoder
-- ============================================================

--- Decode a JSON string into a Lua value.
--- Handles null, boolean, number, string, array, and object.
--- Raises an error on invalid JSON.
---@param s string
---@return any
function M.decode_json(s)
  local pos = 1

  local function skip_ws()
    pos = s:match("^%s*()", pos)
  end

  local decode_val  -- forward
  local function decode_string()
    assert(s:sub(pos, pos) == '"', "expected '\"'")
    pos = pos + 1
    local buf = {}
    while pos <= #s do
      local c = s:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(buf)
      elseif c == '\\' then
        pos = pos + 1
        local esc = s:sub(pos, pos)
        pos = pos + 1
        if     esc == '"'  then buf[#buf+1] = '"'
        elseif esc == '\\' then buf[#buf+1] = '\\'
        elseif esc == '/'  then buf[#buf+1] = '/'
        elseif esc == 'n'  then buf[#buf+1] = '\n'
        elseif esc == 'r'  then buf[#buf+1] = '\r'
        elseif esc == 't'  then buf[#buf+1] = '\t'
        elseif esc == 'b'  then buf[#buf+1] = '\b'
        elseif esc == 'f'  then buf[#buf+1] = '\f'
        elseif esc == 'u'  then
          -- \uXXXX → skip (convert to ?)
          buf[#buf+1] = '?'; pos = pos + 4
        else
          buf[#buf+1] = esc
        end
      else
        -- collect a run of plain chars
        local run_end = s:find('[\\"]', pos) or (#s + 1)
        buf[#buf+1] = s:sub(pos, run_end - 1)
        pos = run_end
      end
    end
    error("unterminated string")
  end

  local function decode_array()
    assert(s:sub(pos, pos) == '[', "expected '['")
    pos = pos + 1
    local arr = {}
    skip_ws()
    if s:sub(pos, pos) == ']' then pos = pos + 1; return arr end
    while true do
      skip_ws()
      arr[#arr+1] = decode_val()
      skip_ws()
      local c = s:sub(pos, pos)
      if c == ']' then pos = pos + 1; return arr end
      assert(c == ',', "expected ',' in array")
      pos = pos + 1
    end
  end

  local function decode_object()
    assert(s:sub(pos, pos) == '{', "expected '{'")
    pos = pos + 1
    local obj = {}
    skip_ws()
    if s:sub(pos, pos) == '}' then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local key = decode_string()
      skip_ws()
      assert(s:sub(pos, pos) == ':', "expected ':' after key")
      pos = pos + 1
      skip_ws()
      obj[key] = decode_val()
      skip_ws()
      local c = s:sub(pos, pos)
      if c == '}' then pos = pos + 1; return obj end
      assert(c == ',', "expected ',' in object")
      pos = pos + 1
    end
  end

  decode_val = function()
    skip_ws()
    local c = s:sub(pos, pos)
    if c == '"' then
      return decode_string()
    elseif c == '[' then
      return decode_array()
    elseif c == '{' then
      return decode_object()
    elseif s:sub(pos, pos+3) == "true" then
      pos = pos + 4; return true
    elseif s:sub(pos, pos+4) == "false" then
      pos = pos + 5; return false
    elseif s:sub(pos, pos+3) == "null" then
      pos = pos + 4; return nil
    else
      -- number
      local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      assert(num_str, "unexpected token at pos " .. pos .. ": " .. s:sub(pos, pos+10))
      pos = pos + #num_str
      return tonumber(num_str)
    end
  end

  local val = decode_val()
  return val
end

return M
