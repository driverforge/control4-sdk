-- =============================================================================
-- stacktrace.lua — structured Lua stack-trace capture for the Anvil SDK.
--
-- Derived from StackTracePlus by Ignacio Burgueño:
--   https://github.com/ignacio/StackTracePlus
--
-- Original work, reproduced under its MIT license:
--
--   The MIT License
--
--   Copyright (c) 2010 Ignacio Burgueño
--
--   Permission is hereby granted, free of charge, to any person obtaining a copy
--   of this software and associated documentation files (the "Software"), to deal
--   in the Software without restriction, including without limitation the rights
--   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--   copies of the Software, and to permit persons to whom the Software is
--   furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in
--   all copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
--   THE SOFTWARE.
--
-- Portions modified by Driverforge Pty Ltd, 2026. Modifications are released under the
-- same MIT license (see the repository LICENSE and THIRD_PARTY_LICENSES).
--
-- Changes from upstream StackTracePlus:
--   * Packaged as a self-contained module (wrapped in an immediately-invoked
--     function that returns the module table) so it can be squished into the
--     single-file SDK bundle.
--   * Removed all reading of source files from disk. Upstream used `io.open`
--     to fetch source lines when guessing a function's name; the Control4 Lua
--     sandbox blocks `io.open`, so GuessFunctionName now returns "?" for
--     file-backed ('@') chunks instead.
--   * Reworked the Dumper to emit a STRUCTURED trace instead of a formatted
--     string: frames are collected as a list of { text, locals } tables and
--     locals as { type, name, value } tables, so a trace can be serialised to
--     JSON and shipped to the Anvil backend. Added toJSON(), addFrame(),
--     removeFrames(), makeLocal() and GetLocals(); kept print() for a
--     human-readable rendering.
--   * stacktrace() now returns the Dumper object (carrying .frames and
--     .message) plus the original error, rather than a concatenated string.
--   * Fixed character-encoding corruption in the original comments
--     ("naïve", "más").
-- =============================================================================

local Stacktrace = (function()
    -- tables
    local _G = _G
    local string, debug, coroutine = string, debug, coroutine

    -- functions
    local tostring, print, require = tostring, print, require
    local next, assert = next, assert
    local pcall, type, pairs, ipairs = pcall, type, pairs, ipairs
    local error = error

    assert(debug, "debug table must be available at this point")

    local string_gmatch = string.gmatch
    local string_sub = string.sub
    local table_concat = table.concat

    local _M = {
        max_string_output_len = 512,	-- maximum length of a captured string value before cutting with ' ...(truncated, N chars)'
        max_table_depth = 3,	-- table locals: nesting levels rendered before '[table depth-capped]'
        max_table_breadth = 20,	-- table locals: entries rendered per table before '...(+N more entries)'
        max_table_render_len = 2048	-- table locals: total render budget per local — breadth compounds per level (breadth^depth leaves), so per-entry caps alone leave a multi-MB worst case
    }

    -- this tables should be weak so the elements in them won't become uncollectable
    local m_known_tables = { [_G] = "_G (global table)" }
    local function add_known_module(name, desc)
        local ok, mod = pcall(require, name)
        if ok then
            m_known_tables[mod] = desc
        end
    end

    add_known_module("string", "string module")
    add_known_module("io", "io module")
    add_known_module("os", "os module")
    add_known_module("table", "table module")
    add_known_module("math", "math module")
    add_known_module("package", "package module")
    add_known_module("debug", "debug module")
    add_known_module("coroutine", "coroutine module")

    -- lua5.2
    add_known_module("bit32", "bit32 module")
    -- luajit
    add_known_module("bit", "bit module")
    add_known_module("jit", "jit module")
    -- lua5.3
    if _VERSION >= "Lua 5.3" then
        add_known_module("utf8", "utf8 module")
    end


    local m_user_known_tables = {}

    local m_known_functions = {}
    for _, name in ipairs{
        -- Lua 5.2, 5.1
        "assert",
        "collectgarbage",
        "dofile",
        "error",
        "getmetatable",
        "ipairs",
        "load",
        "loadfile",
        "next",
        "pairs",
        "pcall",
        "print",
        "rawequal",
        "rawget",
        "rawlen",
        "rawset",
        "require",
        "select",
        "setmetatable",
        "tonumber",
        "tostring",
        "type",
        "xpcall",

        -- Lua 5.1
        "gcinfo",
        "getfenv",
        "loadstring",
        "module",
        "newproxy",
        "setfenv",
        "unpack",
    } do
        if _G[name] then
            m_known_functions[_G[name]] = name
        end
    end

    local m_user_known_functions = {}

    local function safe_tostring (value)
        local ok, err = pcall(tostring, value)
        if ok then return err else return ("<failed to get printable value>: '%s'"):format(err) end
    end

    -- Bound captured string values: a large buffer held in a local (network
    -- payload, file contents) would otherwise ship whole inside a single
    -- error envelope. The marker keeps the original size visible wherever
    -- the value is displayed.
    local function truncate_string(value)
        if #value <= _M.max_string_output_len then
            return value
        end
        return string_sub(value, 1, _M.max_string_output_len)
            .. (" ...(truncated, %d chars)"):format(#value)
    end

    -- Non-table leaf inside a table local. Functions/userdata/threads render
    -- as bare type placeholders: their tostring() is an address, which is
    -- noise on another machine's screen.
    local function dump_leaf(value)
        local t = type(value)
        if t == "string" then return truncate_string(value) end
        if t == "function" then return "[function]" end
        if t == "userdata" then return "[userdata]" end
        if t == "thread" then return "[thread]" end
        return safe_tostring(value)  -- number, boolean, nil
    end

    -- Structured rendering of a table local, bounded on three axes plus a
    -- total budget: depth (nesting), breadth (entries per table), leaf
    -- string cap, and an overall per-local character budget. The hard depth
    -- limit is also the termination guarantee for cyclic tables (a cycle
    -- renders until the depth cap, then '[table depth-capped]').
    -- Known tables (e.g. _G) render as their registered name at any level.
    local function dump_table(value, depth, budget)
        local known = m_known_tables[value] or m_user_known_tables[value]
        if known then return known end
        if depth > _M.max_table_depth then return "[table depth-capped]" end

        local parts = {}
        local count, shown = 0, 0
        for k, v in pairs(value) do
            count = count + 1
            if shown < _M.max_table_breadth and budget.remaining > 0 then
                local rendered
                if type(v) == "table" then
                    rendered = dump_table(v, depth + 1, budget)
                else
                    rendered = dump_leaf(v)
                end
                local entry = truncate_string(safe_tostring(k)) .. ":" .. rendered
                parts[#parts + 1] = entry
                shown = shown + 1
                budget.remaining = budget.remaining - #entry
            end
        end
        if count > shown then
            parts[#parts + 1] = ("...(+%d more entries)"):format(count - shown)
        end
        return "{" .. table_concat(parts, ", ") .. "}"
    end

    -- Private:
    -- Parses a line, looking for possible function definitions (in a very naïve way)
    -- Returns '(anonymous)' if no function name was found in the line
    local function ParseLine(line)
        assert(type(line) == "string")
        --print(line)
        local match = line:match("^%s*function%s+(%w+)")
        if match then
            --print("+++++++++++++function", match)
            return match
        end
        match = line:match("^%s*local%s+function%s+(%w+)")
        if match then
            --print("++++++++++++local", match)
            return match
        end
        match = line:match("^%s*local%s+(%w+)%s+=%s+function")
        if match then
            --print("++++++++++++local func", match)
            return match
        end
        match = line:match("%s*function%s*%(")	-- this is an anonymous function
        if match then
            --print("+++++++++++++function2", match)
            return "(anonymous)"
        end
        return "(anonymous)"
    end

    -- Private:
    -- Tries to guess a function's name when the debug info structure does not have it.
    -- It parses either the file or the string where the function is defined.
    -- Returns '?' if the line where the function is defined is not found
    local function GuessFunctionName(info)
        --print("guessing function name")
        if type(info.source) == "string" and info.source:sub(1,1) == "@" then
            -- File sources can't be read on Control4 (io.open is blocked)
            return "?"
        else
            local line
            local lineNumber = 0
            for l in string_gmatch(info.source, "([^\n]+)\n-") do
                lineNumber = lineNumber + 1
                if lineNumber == info.linedefined then
                    line = l
                    break
                end
            end
            if not line then
                -- Source line unavailable (stripped chunk, mismatched
                -- linedefined): degrade silently — this is library code and
                -- a best-guess path; printing here would spam the Lua output.
                return "?"
            end
            return ParseLine(line)
        end
    end

    ---
    -- Dumper instances are used to analyze stacks and collect its information.
    --
    local Dumper = {}

    Dumper.new = function(thread)
        local t = { message = "", frames = {} }
        for k,v in pairs(Dumper) do t[k] = v end

        t.dumping_same_thread = (thread == coroutine.running())

        -- if a thread was supplied, bind it to debug.info and debug.get
        -- we also need to skip this additional level we are introducing in the callstack (only if we are running
        -- in the same thread we're inspecting)
        if type(thread) == "thread" then
            t.getinfo = function(level, what)
                if t.dumping_same_thread and type(level) == "number" then
                    level = level + 1
                end
                return debug.getinfo(thread, level, what)
            end
            t.getlocal = function(level, loc)
                if t.dumping_same_thread then
                    level = level + 1
                end
                return debug.getlocal(thread, level, loc)
            end
        else
            t.getinfo = debug.getinfo
            t.getlocal = debug.getlocal
        end

        return t
    end

    function Dumper:AppendLocals(linesBuffer, locals)
        local prefix = "\t "

        if #locals > 0 then
            table.insert(linesBuffer, ("\r\n%sLocal variables:\r\n"):format(prefix))
        end

        for _, localData in ipairs(locals) do
            local type = localData["type"]
            local name = localData["name"]
            local value = localData["value"]

            table.insert(linesBuffer, ("%s  %s (%s): %s\r\n"):format(prefix, name, type, value))
        end
    end

    function Dumper:toJSON()
        return self.frames
    end

    function Dumper:print()
        local prefix = "\t "
        local lines = {}

        table.insert(lines, ("Unhandled error: %s"):format(self.message))
        table.insert(lines, "\r\n")
        table.insert(lines, "\r\n")

        table.insert(lines, [[
Stack Traceback
===============
]])

        table.insert(lines, "\r\n")
        for frameIndex, frame in ipairs(self.frames) do
            local text = ("(%d) %s"):format(frameIndex, frame["text"])
            table.insert(lines, text)

            self:AppendLocals(lines, frame["locals"])
        end

        table.insert(lines, "\r\n")

        print(table.concat(lines))
    end

    function Dumper:addFrame(text, locals)
        local frame = {}
        frame["text"] = text
        frame["locals"] = locals or {}

        self.frames[#self.frames + 1] = frame
    end

    function Dumper:removeFrames(frames)
        for i = 1, frames do
            table.remove(self.frames)
        end
    end
    function Dumper:makeLocal(typeName, name, value)
        local localData = {}
        localData["type"] = typeName
        localData["name"] = name
        localData["value"] = value

        return localData
    end

    function Dumper:GetLocals(level)
        local i = 1
        local locals = {}

        if self.dumping_same_thread then
            level = level + 1
        end

        local name, value = self.getlocal(level, i)
        if not name then
            return locals
        end

        while name do
            local localData = {}
            if type(value) == "number" then
                localData = self:makeLocal("number", name, value)
            elseif type(value) == "boolean" then
                localData = self:makeLocal("boolean", name, tostring(value))
            elseif type(value) == "string" then
                localData = self:makeLocal("string", name, truncate_string(value))
            elseif type(value) == "userdata" then
                localData = self:makeLocal("userdata", name, safe_tostring(value))
            elseif type(value) == "nil" then
                localData = self:makeLocal("nil", name, "nil")
            elseif type(value) == "table" then
                localData = self:makeLocal("table", name,
                    dump_table(value, 1, { remaining = _M.max_table_render_len }))
            elseif type(value) == "function" then
                local info = self.getinfo(value, "nS")
                local fun_name = info.name or m_known_functions[value] or m_user_known_functions[value]
                if info.what == "C" then
                    localData = self:makeLocal("function", name, (fun_name and ("C function: " .. fun_name) or tostring(value)))
                else
                    local source = info.short_src
                    if source:sub(2,7) == "string" then
                        source = source:sub(9)	-- uno más, por el espacio que viene (string "Baragent.Main", por ejemplo)
                    end
                    --for k,v in pairs(info) do print(k,v) end
                    fun_name = fun_name or GuessFunctionName(info)
                    localData = self:makeLocal("function", fun_name, ("Lua function '%s' (defined at line %d of chunk %s)"):format(fun_name, info.linedefined, source))
                end
            elseif type(value) == "thread" then
                localData = self:makeLocal("thread", name, tostring(value))
            else
                -- Anything the branches above don't know (e.g. LuaJIT
                -- cdata). Without this default the empty placeholder makes
                -- AppendLocals's format() throw INSIDE the error handler.
                localData = self:makeLocal(type(value), name, safe_tostring(value))
            end
            locals[#locals + 1] = localData
            i = i + 1
            name, value = self.getlocal(level, i)
        end

        return locals
    end

    ---
    -- Public:
    -- Collects a detailed stack trace, dumping locals, resolving function names when they're not available, etc.
    -- This function is suitable to be used as an error handler with pcall or xpcall
    --
    -- @param thread An optional thread whose stack is to be inspected (defaul is the current thread)
    -- @param message An optional error string or object.
    -- @param level An optional number telling at which level to start the traceback (default is 1)
    --
    -- Returns a string with the stack trace and a string with the original error.
    --
    function _M.stacktrace(thread, message, level)
        if type(thread) ~= "thread" then
            -- shift parameters left
            thread, message, level = nil, thread, message
        end

        thread = thread or coroutine.running()

        level = level or 1

        local dumper = Dumper.new(thread)

        local original_error = message

        if dumper.dumping_same_thread then level = level + 1 end

        local info = dumper.getinfo(level, "nSlf")
        while info do
            if info.what == "main" then
                local text = ""

                if string_sub(info.source, 1, 1) == "@" then
                    text = ("main chunk of file '%s' at line %d"):format(string_sub(info.source, 2), info.currentline)
                else
                    text = ("main chunk of %s at line %d"):format(info.short_src, info.currentline)
                end

                dumper:addFrame(text)
            elseif info.what == "C" then
                local function_name = m_user_known_functions[info.func] or m_known_functions[info.func] or info.name or tostring(info.func)
                local text = ("%s C function '%s'"):format(info.namewhat, function_name)

                dumper:addFrame(text)
            elseif info.what == "tail" then
                local locals = dumper:GetLocals(level)

                dumper:addFrame("tail call", locals)
            elseif info.what == "Lua" then
                local locals = dumper:GetLocals(level)
                local source = info.short_src
                local function_name = m_user_known_functions[info.func] or m_known_functions[info.func] or info.name

                if source:sub(2, 7) == "string" then
                    source = source:sub(9)
                end

                local was_guessed = false

                if not function_name or function_name == "?" then
                    function_name = GuessFunctionName(info)
                    was_guessed = true
                end

                -- test if we have a file name
                local function_type = (info.namewhat == "") and "function" or info.namewhat
                local text = ""

                if info.source and info.source:sub(1, 1) == "@" then
                    text = ("Lua %s '%s' in '%s:%d'%s"):format(function_type, function_name, info.source:sub(2), info.currentline, was_guessed and " (best guess)" or "")
                elseif info.source and info.source:sub(1,1) == '#' then
                    text = ("Lua %s '%s' at template '%s:%d'%s"):format(function_type, function_name, info.source:sub(2), info.currentline, was_guessed and " (best guess)" or "")
                else
                    text = ("Lua %s '%s' at line %d  of chunk '%s'"):format(function_type, function_name, info.currentline, source)
                end

                dumper:addFrame(text, locals)
            else
                local text = ("unknown frame %s"):format(info.what)

                dumper:addFrame(text)
            end

            level = level + 1
            info = dumper.getinfo(level, "nSlf")
        end

        dumper.message = original_error
        return dumper, original_error
    end

    --
    -- Adds a table to the list of known tables
    function _M.add_known_table(tab, description)
        if m_known_tables[tab] then
            error("Cannot override an already known table")
        end
        m_user_known_tables[tab] = description
    end

    --
    -- Adds a function to the list of known functions
    function _M.add_known_function(fun, description)
        if m_known_functions[fun] then
            error("Cannot override an already known function")
        end
        m_user_known_functions[fun] = description
    end

    return _M
end)()

return Stacktrace