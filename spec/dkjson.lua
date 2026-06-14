-- dkjson.lua - minimal Lua JSON library compatible with the dkjson API
-- decode(s) -> value, pos, err  (returns nil,pos,err on failure; nil for invalid JSON)
-- encode(v) -> string

local M = {}

local function skip_ws(s, i)
    while i <= #s do
        local c = s:sub(i,i)
        if c == ' ' or c == '\t' or c == '\n' or c == '\r' then i = i + 1
        else break end
    end
    return i
end

local decode_value  -- forward declaration

local function decode_string(s, i)
    -- i points at opening "
    local res = {}
    i = i + 1
    while i <= #s do
        local c = s:sub(i,i)
        if c == '"' then return table.concat(res), i+1 end
        if c == '\\' then
            local e = s:sub(i+1,i+1)
            if     e == '"'  then res[#res+1] = '"'
            elseif e == '\\' then res[#res+1] = '\\'
            elseif e == '/'  then res[#res+1] = '/'
            elseif e == 'n'  then res[#res+1] = '\n'
            elseif e == 'r'  then res[#res+1] = '\r'
            elseif e == 't'  then res[#res+1] = '\t'
            elseif e == 'b'  then res[#res+1] = '\b'
            elseif e == 'f'  then res[#res+1] = '\f'
            elseif e == 'u'  then
                local hex = s:sub(i+2, i+5)
                local cp = tonumber(hex, 16)
                if cp then
                    if cp < 0x80 then
                        res[#res+1] = string.char(cp)
                    elseif cp < 0x800 then
                        res[#res+1] = string.char(0xC0 + math.floor(cp/64), 0x80 + cp%64)
                    else
                        res[#res+1] = string.char(0xE0 + math.floor(cp/4096),
                            0x80 + math.floor(cp/64)%64, 0x80 + cp%64)
                    end
                end
                i = i + 4
            end
            i = i + 2
        else
            res[#res+1] = c
            i = i + 1
        end
    end
    return nil, i, "unterminated string"
end

local function decode_array(s, i)
    local arr = {}
    i = i + 1  -- skip [
    i = skip_ws(s, i)
    if s:sub(i,i) == ']' then return arr, i+1 end
    while true do
        local v, ni, err = decode_value(s, i)
        if err then return nil, ni, err end
        arr[#arr+1] = v
        i = skip_ws(s, ni)
        local c = s:sub(i,i)
        if c == ']' then return arr, i+1 end
        if c ~= ',' then return nil, i, "expected ',' or ']'" end
        i = skip_ws(s, i+1)
    end
end

local function decode_object(s, i)
    local obj = {}
    i = i + 1  -- skip {
    i = skip_ws(s, i)
    if s:sub(i,i) == '}' then return obj, i+1 end
    while true do
        i = skip_ws(s, i)
        if s:sub(i,i) ~= '"' then return nil, i, "expected string key" end
        local k, ni, err = decode_string(s, i)
        if err then return nil, ni, err end
        i = skip_ws(s, ni)
        if s:sub(i,i) ~= ':' then return nil, i, "expected ':'" end
        i = skip_ws(s, i+1)
        local v, ni2, err2 = decode_value(s, i)
        if err2 then return nil, ni2, err2 end
        obj[k] = v
        i = skip_ws(s, ni2)
        local c = s:sub(i,i)
        if c == '}' then return obj, i+1 end
        if c ~= ',' then return nil, i, "expected ',' or '}'" end
        i = i + 1
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i,i)
    if c == '"' then return decode_string(s, i)
    elseif c == '{' then return decode_object(s, i)
    elseif c == '[' then return decode_array(s, i)
    elseif c == 't' then
        if s:sub(i,i+3) == 'true' then return true, i+4 end
    elseif c == 'f' then
        if s:sub(i,i+4) == 'false' then return false, i+5 end
    elseif c == 'n' then
        if s:sub(i,i+3) == 'null' then return nil, i+4 end  -- returns nil (valid)
    elseif c == '-' or (c >= '0' and c <= '9') then
        local num_str = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
        if num_str then return tonumber(num_str), i + #num_str end
    end
    return nil, i, "unexpected character: " .. c
end

function M.decode(s, pos, nullval, ...)
    if type(s) ~= 'string' then return nil, 1, 'not a string' end
    pos = pos or 1
    local ok, val_or_err, ni, err = pcall(function()
        return decode_value(s, pos)
    end)
    if not ok then return nil, pos, tostring(val_or_err) end
    local v, np, e = val_or_err, ni, err
    if e then return nil, np, e end
    return v, np
end

-- Encode
local function encode_val(v, seen)
    local t = type(v)
    if t == 'nil' then return 'null'
    elseif t == 'boolean' then return tostring(v)
    elseif t == 'number' then
        if v ~= v then return 'null' end  -- NaN
        return tostring(v)
    elseif t == 'string' then
        return '"' .. v:gsub('[\\"/\0-\31]', function(c)
            local special = {['\\']='\\\\', ['"']='\\"', ['/']='\\/',
                ['\n']='\\n', ['\r']='\\r', ['\t']='\\t', ['\b']='\\b', ['\f']='\\f'}
            return special[c] or ('\\u00' .. string.format('%02x', string.byte(c)))
        end) .. '"'
    elseif t == 'table' then
        if seen[v] then return 'null' end
        seen[v] = true
        -- check if array
        local is_arr = true
        local max = 0
        for k, _ in pairs(v) do
            if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
                is_arr = false; break
            end
            if k > max then max = k end
        end
        if is_arr and max == #v then
            local parts = {}
            for _, item in ipairs(v) do parts[#parts+1] = encode_val(item, seen) end
            seen[v] = nil
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local parts = {}
            for k, vv in pairs(v) do
                if type(k) == 'string' then
                    parts[#parts+1] = encode_val(k, seen) .. ':' .. encode_val(vv, seen)
                end
            end
            seen[v] = nil
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'null'
end

function M.encode(v, state)
    return encode_val(v, {})
end

function M.new()
    return M
end

return M
