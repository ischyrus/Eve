util = require("util")
math = require("math")
parser = require("parser")

function recurse_print_table(t)
   if t == nil then return nil end
   local result = ""
   for k, v in pairs(t) do
      result = result .. " " .. tostring(k) .. ":"
     if (type(v) == "table") then
        result = result .. "{" .. recurse_print_table(v) .. "}"
     else
        result = result .. tostring(v)
     end
   end
   return result
end

function flat_print_table(t)
   if type(t) == "table" then 
     local result = ""
     for k, v in pairs(t) do
        result = result .. " " .. tostring(k) .. ":"
        result = result .. tostring(v)
     end
     return result
   end
   return tostring(t)
end

function deepcopy(orig)
   local orig_type = type(orig)
   local copy
   if orig_type == 'table' then
       copy = {}
       for orig_key, orig_value in next, orig, nil do
              copy[deepcopy(orig_key)] = deepcopy(orig_value)
       end
    else -- number, string, boolean, etc
       copy = orig
    end
   return copy
end

function shallowcopy(orig)
    local copy = {}
    for k, v in pairs(orig) do
       copy[k] = v
    end
    return copy
end

-- end of util

function empty_env()
   return {alloc=0, freelist = {}, registers = {}, permanent = {}, maxregs = 0}
end

function variable(x)
   return type(x) == "table" and x.type == "variable"
end


function free_register(env, e)
   if env.permanent[e] == nil and env.registers[e] then
     env.freelist[env.registers[e]] = true
     env.registers[e] = nil
     while(env.freelist[env.alloc-1]) do
        env.alloc = env.alloc - 1
        env.freelist[env.alloc] = nil
     end
   end
end

function allocate_register(env, e)
   if not variable(e) or env.registers[e] then return end
   slot = env.alloc
   for index,value in ipairs(env.freelist) do
      slot = math.min(slot, index)
   end
   if slot == env.alloc then env.alloc = env.alloc + 1
   else env.freelist[slot] = nil end
   env.registers[e] = slot
   env.maxregs = math.max(env.maxregs, slot)
   return slot
end

function read_lookup(env, x)
   if variable(x) then
      local r = env.registers[x]
      if not r then
         r = allocate_register(env, x)
         env.registers[x] = r
       end
      return register(r)
   end
   -- demultiplex types on x.constantType
   if type(x) == "table" then
      return x["constant"]
   end
   return x
end

function write_lookup(env, x)
   -- can't be a constant or unbound
   r = env.registers[x]
   free_register(env, x)
   return register(r)
end


function bound_lookup(bindings, x)
   if variable(x) then
         return bindings[x]
   end
   return x
end

function translate_subproject(n, bound, down)
   local p = n.projection
   local t = n.nodes
   local prod = n.produces
   print ("subproject", p, t, prod, flat_print_table(n))
   env, c2 = walk(n.produces, nil, c, env, nk)    
   return env, build_node("sub", {c, c2}, {}, {})
   
end

function translate_object(n, bound, down)
   local e = n.entity
   local a = n.attribute
   local v = n.value
   local sig = "EAV"
   local ef = read_lookup
   local af = read_lookup
   local vf = read_lookup

   if not bound_lookup(bound, e) then 
       sig = "eAV"
       bound[e] = true
       ef = write_lookup
   end
   if not bound_lookup(bound, a) then 
       sig = string.sub(sig, 0, 1) .. "aV"
       bound[a] = true
       af = write_lookup
   end
   if not bound_lookup(bound, v) then 
       sig = string.sub(sig, 0, 2) .. "v"
       bound[v] = true
       vf = write_lookup
   end

   local env, c = down(bound)
   return env, build_node("scan", {c}, {ef(env, e), af(env, a), vf(env, v)}, {})
 end


function translate_mutate(n, bound, down)
   local e = n.entity
   local a = n.attribute
   local v = n.value

   local gen = (variable(e) and not bound[e])
   if (gen) then bound[e] = true end
   local env, c = down(bound)
   local c = build_node("insert", {c}, {n.scope, ef(env, e), af(env, a), vf(env, v)}, {})
   if gen then
      c = generate_uuid(ex, c, write_lookup(env, e))
   end
   return env, c
end

function translate_union(n, bound, down)
   local heads
   local c2
   local arms = {}
   tail_bound = shallowcopy(bound)
   
   
   for _, v in pairs(n.outputs) do
      tail_bound[v] = true
   end

   local env, c = down(tail_bound)
         
   local orig_perm = shallowcopy(env.permanent)
   for n, _ in pairs(env.registers) do
      env.permanent[n] = true
   end
   
   for _, v in pairs(n.queries) do
      local c2
      env, c2 = walk(v.unpacked, nil, shallowcopy(bound), c, env, nk)
      arms[#arms+1] = c2 
   end
   env.permanent = orig_perm
   -- currently leaking the perms
   return env, build_node("fork", arms, {}, {})
end

-- this doesn't really need to be disjoint from read lookup, except for concerns about
-- environment mutation - be sure to use the same type multiplexing
function trace_lookup(env, x)
   if variable(x) then
      local r = env.registers[x]
      return register(r)
   end
   -- demultiplex types on x.constantType
   if type(x) == "table" then
      return x["constant"]
   end
   return x
end

function trace(ex, n, bound, down)
--    local entry = shallowcopy(bound)
    local env, c = down(bound)
    local map = {}
--    for n, v in pairs(entry) do
--       map[n.name] = env.registers[n]
--    end
    if (n.type == "mutate") or (n.type == "object") then

       return env, build_node("trace", {c},
                              {"entity", trace_lookup(env, n.entity),
                               "attribute", trace_lookup(env, n.attribute),
                               "value", trace_lookup(env, n.value)},
                             {})
    end
    return env, c
end

function walk(graph, key, bound, tail, tail_env, tracing)
   local d
   nk = next(graph, key)
   if not nk then
      return tail_env, tail
   end

   local n = graph[nk]

   print("walk: ", n.type) 

   down = function (bound)
                return walk(graph, nk, bound, tail, tail_env, tracing)
           end
           
   if tracing then
      d = function (bound)
                  return trace(n, bound, down)
          end
   else d = down end       


   if (n.type == "union") then
      return translate_union(n, bound, d)
   end
   if (n.type == "mutate") then
      return translate_mutate(n, bound, d)
   end
   if (n.type == "object") then
      return translate_object(n, bound, d)
   end
   if (n.type == "subproject") then
      return translate_subproject(n, bound, d)
   end

   print ("ok, so we kind of suck right now and only handle some fixed patterns",
         "type", n.type,
         "entity", flat_print_table(e),
         "attribute", flat_print_table(a),
         "value", flat_print_table(v))
end


function build(graphs, tracing)
   local head
   local regs = 0
   for _, g in pairs(graphs) do
      local env, program = walk(g, nil, {}, build_node("terminal", {}, {}), empty_env(), tracing)
      regs = math.max(regs, env.maxregs + 1)
      if head then
         head = build_fork(ex, head, program)
      else
         head = program
      end
   end
   set_head(ex, head, regs)
   return ex
end

------------------------------------------------------------
-- Parser interface
------------------------------------------------------------

return {
  build = build
}
