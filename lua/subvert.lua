-- subvert.lua
-- Lua port of abolish.vim's :Subvert command for Neovim
-- Supports live preview via 'inccommand' / command-preview.
--
-- Usage:  require("subvert").setup()
--   :S/pattern/replacement/flags
--   :S/search
--   :S/search/ grep-args

local M = {}

-------------------------------------------------------------------------------
-- Case coercion helpers {{{1
-------------------------------------------------------------------------------

local function camelcase(word)
  word = word:gsub("%-", "_")
  if not word:find("_") and word:match("%l") then
    return (word:gsub("^.", string.lower))
  end
  local out = ""
  local first = true
  for part in word:gmatch("[^_]+") do
    if first then
      out = out .. part:lower()
      first = false
    else
      out = out .. part:sub(1, 1):upper() .. part:sub(2):lower()
    end
  end
  return out
end

local function mixedcase(word)
  local c = camelcase(word)
  return c:sub(1, 1):upper() .. c:sub(2)
end

local function snakecase(word)
  word = word:gsub("::", "/")
  word = word:gsub("(%u+)(%u%l)", "%1_%2")
  word = word:gsub("([%l%d])(%u)", "%1_%2")
  word = word:gsub("[%.%-]", "_")
  return word:lower()
end

local function uppercase(word)
  return snakecase(word):upper()
end

local function dashcase(word)
  return (snakecase(word):gsub("_", "-"))
end

local function spacecase(word)
  return (snakecase(word):gsub("_", " "))
end

local function dotcase(word)
  return (snakecase(word):gsub("_", "."))
end

-- }}}1
-------------------------------------------------------------------------------
-- Brace expansion {{{1
-------------------------------------------------------------------------------

local function expand_braces(dict)
  local new_dict = {}
  local redo = false
  for key, val in pairs(dict) do
    local kb, km, ka = key:match("^(.-){(.-)}(.*)$")
    if kb then
      redo = true
      local vb, vm, va = val:match("^(.-){(.-)}(.*)$")
      if not vb then
        vb, vm, va = val, ",", ""
      end
      local targets = {}
      for t in (km .. ","):gmatch("([^,]*),") do
        targets[#targets + 1] = t
      end
      local replacements = {}
      for r in (vm .. ","):gmatch("([^,]*),") do
        replacements[#replacements + 1] = r
      end
      if #replacements == 1 and replacements[1] == "" then
        replacements = targets
      end
      for i, t in ipairs(targets) do
        local ri = ((i - 1) % #replacements) + 1
        new_dict[kb .. t .. ka] = vb .. replacements[ri] .. va
      end
    else
      new_dict[key] = val
    end
  end
  if redo then
    return expand_braces(new_dict)
  end
  return new_dict
end

-- }}}1
-------------------------------------------------------------------------------
-- Dictionary creation {{{1
-------------------------------------------------------------------------------

local function create_dictionary(lhs, rhs, opts)
  local dict = {}
  local expanded = expand_braces({ [lhs] = rhs })
  local use_case = opts.case ~= false and opts.case ~= 0
  for l, r in pairs(expanded) do
    if use_case then
      dict[mixedcase(l)] = mixedcase(r)
      dict[l:lower()] = r:lower()
      dict[l:upper()] = r:upper()
    end
    dict[l] = r
  end
  return dict
end

-- }}}1
-------------------------------------------------------------------------------
-- Pattern helpers {{{1
-------------------------------------------------------------------------------

local function subesc(s)
  return (s:gsub("([%]%[/\\%.%*%+%?~%%%(%)&])", "\\%1"))
end

local function sort_keys(a, b)
  if a:lower() == b:lower() then
    return a < b
  end
  if #a ~= #b then
    return #a > #b
  end
  return a:lower() < b:lower()
end

local function sorted_keys(dict)
  local keys = {}
  for k in pairs(dict) do
    keys[#keys + 1] = k
  end
  table.sort(keys, sort_keys)
  return keys
end

local function build_pattern(dict, boundaries)
  local a, b
  if boundaries == 2 then
    a, b = "<", ">"
  elseif boundaries == 1 then
    a = "%(<|_@<=|[[:lower:]]@<=[[:upper:]]@=)"
    b = "%(>|_@=|[[:lower:]]@<=[[:upper:]]@=)"
  else
    a, b = "", ""
  end
  local parts = {}
  for _, k in ipairs(sorted_keys(dict)) do
    parts[#parts + 1] = subesc(k)
  end
  return "\\v\\C"
    .. a
    .. "%("
    .. table.concat(parts, "|")
    .. ")"
    .. b
end

-- }}}1
-------------------------------------------------------------------------------
-- Flag / option normalisation {{{1
-------------------------------------------------------------------------------

local function normalize_options(flags_or_opts)
  local opts, flags
  if type(flags_or_opts) == "table" then
    opts = vim.deepcopy(flags_or_opts)
    flags = opts.flags or ""
  else
    opts = {}
    flags = flags_or_opts or ""
  end
  if flags:find("w") then
    opts.boundaries = 2
  elseif flags:find("v") then
    opts.boundaries = 1
  elseif not opts.boundaries then
    opts.boundaries = 0
  end
  if flags:find("I") then
    opts.case = 0
  elseif opts.case == nil then
    opts.case = 1
  end
  opts.flags = flags:gsub("[avIiw]", "")
  return opts
end

-- }}}1
-------------------------------------------------------------------------------
-- Subvert argument parsing {{{1
-------------------------------------------------------------------------------

local function parse_subvert_args(bang, count, raw_args)
  local args = raw_args
  if args:match("^[%w]") or args == "" then
    args = (bang and "!" or "") .. args
  end

  local sep_char = args:sub(1, 1)
  local rest = args:sub(2)

  -- Split on unescaped separator
  local parts = {}
  local i = 1
  local cur = ""
  while i <= #rest do
    local ch = rest:sub(i, i)
    if ch == "\\" and i < #rest then
      local nch = rest:sub(i + 1, i + 1)
      if nch == sep_char then
        cur = cur .. sep_char
        i = i + 2
      else
        cur = cur .. ch .. nch
        i = i + 2
      end
    elseif ch == sep_char then
      parts[#parts + 1] = cur
      cur = ""
      i = i + 1
    else
      cur = cur .. ch
      i = i + 1
    end
  end
  parts[#parts + 1] = cur

  if count > 0 or #parts == 0 then
    return { mode = "substitute", parts = parts, sep = sep_char }
  elseif #parts == 1 then
    return { mode = "search", pattern = parts[1], flags = "" }
  elseif
    #parts == 2 and parts[2]:match("^[A-Za-z]*n[A-Za-z]*$")
  then
    return {
      mode = "substitute",
      parts = { parts[1], "", parts[2] },
      sep = sep_char,
    }
  elseif
    #parts == 2 and parts[2]:match("^[A-Za-z]*[%+%-]?%d*$")
  then
    return {
      mode = "search",
      pattern = parts[1],
      flags = parts[2],
    }
  elseif #parts >= 2 and parts[2]:match("^[A-Za-z]* ") then
    local gflags = parts[2]:match("^([A-Za-z]*)")
    local grep_rest = parts[2]:match("^[A-Za-z]* (.*)$")
    for j = 3, #parts do
      grep_rest = grep_rest .. sep_char .. parts[j]
    end
    return {
      mode = "grep",
      pattern = parts[1],
      flags = gflags,
      grep_args = grep_rest,
    }
  elseif #parts >= 2 and sep_char == " " then
    return {
      mode = "grep",
      pattern = parts[1],
      flags = "",
      grep_args = table.concat(parts, " ", 2),
    }
  else
    return { mode = "substitute", parts = parts, sep = sep_char }
  end
end

-- }}}1
-------------------------------------------------------------------------------
-- Abolished() replacement function {{{1
-------------------------------------------------------------------------------

M._last_dict = {}

function M._abolished()
  local match = vim.fn.submatch(0)
  return M._last_dict[match] or match
end

-- }}}1
-------------------------------------------------------------------------------
-- Build the :substitute command string {{{1
-------------------------------------------------------------------------------

local function build_substitute_cmd(range, bad, good, flags_input)
  local opts = normalize_options(flags_input)
  local dict = create_dictionary(bad, good, opts)
  local pat = build_pattern(dict, opts.boundaries)
  M._last_dict = dict
  local sub_flags = opts.flags
  return range
    .. "s/"
    .. pat
    .. "/\\=v:lua.require('subvert')._abolished()/"
    .. sub_flags,
    dict,
    pat
end

-- }}}1
-------------------------------------------------------------------------------
-- Search {{{1
-------------------------------------------------------------------------------

local function do_search(pattern, flags_str)
  local opts = normalize_options(flags_str)
  local dict = create_dictionary(pattern, "", opts)
  local pat = build_pattern(dict, opts.boundaries)
  vim.fn.setreg("/", pat)
  vim.cmd("nohlsearch")
  vim.cmd("normal! n")
  vim.opt.hlsearch = true
end

-- }}}1
-------------------------------------------------------------------------------
-- Grep {{{1
-------------------------------------------------------------------------------

local function egrep_pattern(dict, boundaries)
  local a, b
  if boundaries == 2 then
    a, b = "\\<", "\\>"
  elseif boundaries == 1 then
    a = "(\\<\\|_)"
    b = "(\\>\\|_\\|[[:upper:]][[:lower:]])"
  else
    a, b = "", ""
  end
  local parts = {}
  for _, k in ipairs(sorted_keys(dict)) do
    parts[#parts + 1] = subesc(k)
  end
  return a
    .. "("
    .. table.concat(parts, "\\|")
    .. ")"
    .. b
end

local function do_grep(bang, pattern, flags_str, grep_args)
  local opts = normalize_options(flags_str)
  local dict = create_dictionary(pattern, "", opts)
  local grepprg = vim.o.grepprg
  local lhs
  if grepprg == "internal" then
    lhs = "'" .. build_pattern(dict, opts.boundaries) .. "'"
  elseif grepprg:match("^rg") or grepprg:match("^ag") then
    lhs = "'" .. egrep_pattern(dict, opts.boundaries) .. "'"
  else
    lhs = "-E '" .. egrep_pattern(dict, opts.boundaries) .. "'"
  end
  vim.cmd(
    "grep"
      .. (bang and "!" or "")
      .. " "
      .. lhs
      .. " "
      .. grep_args
  )
end

-- }}}1
-------------------------------------------------------------------------------
-- Execute (non-preview) {{{1
-------------------------------------------------------------------------------

local function execute_subvert(bang, line1, line2, count, raw_args)
  local parsed = parse_subvert_args(bang, count, raw_args)

  if parsed.mode == "search" then
    do_search(parsed.pattern, parsed.flags)
    return
  end

  if parsed.mode == "grep" then
    do_grep(bang, parsed.pattern, parsed.flags, parsed.grep_args)
    return
  end

  local parts = parsed.parts
  if #parts < 2 then
    vim.api.nvim_err_writeln("Subvert: E471: Argument required")
    return
  end
  if #parts > 3 then
    vim.api.nvim_err_writeln("Subvert: E488: Trailing characters")
    return
  end

  local bad = parts[1]
  local good = parts[2]
  local flags = parts[3] or ""

  local range
  if count == 0 then
    range = ""
  else
    range = line1 .. "," .. line2
  end

  local cmd = build_substitute_cmd(range, bad, good, flags)
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.api.nvim_err_writeln("Subvert: " .. tostring(err))
  end
end

-- }}}1
-------------------------------------------------------------------------------
-- Collect matches on a single line {{{1
-------------------------------------------------------------------------------

--- Find all matches of `pat` (a \v pattern) in `line`.
--- If `use_g` is false, stops after the first match.
--- Returns a list of { ms = <0-based start>, me = <0-based end>,
---                      matched = <text>, replacement = <text> }
local function collect_line_matches(line, pat, dict, use_g)
  local matches = {}
  local col = 0
  while true do
    local mpos = vim.fn.matchstrpos(line, pat, col)
    local matched = mpos[1]
    local ms = mpos[2]
    local me = mpos[3]
    if ms == -1 then
      break
    end
    matches[#matches + 1] = {
      ms = ms,
      me = me,
      matched = matched,
      replacement = dict[matched] or matched,
    }
    -- Advance; handle zero-width matches
    if me == ms then
      col = me + 1
    else
      col = me
    end
    if not use_g then
      break
    end
  end
  return matches
end

-- }}}1
-------------------------------------------------------------------------------
-- Build a replacement line and track highlight positions {{{1
-------------------------------------------------------------------------------

--- Given the original `line` and a sorted list of `matches`,
--- return (new_line, highlights) where highlights is a list of
--- { col_start, col_end } byte offsets into new_line for each
--- replacement.
local function build_replaced_line(line, matches)
  local segments = {}
  local highlights = {}
  local last_end = 0 -- 0-based exclusive end of previous match

  for _, m in ipairs(matches) do
    -- Text between previous match and this match.
    -- Lua sub is 1-based inclusive, so translate:
    --   0-based [last_end, m.ms) → 1-based [last_end+1, m.ms]
    segments[#segments + 1] = line:sub(last_end + 1, m.ms)

    -- Byte offset where the replacement starts in the new line
    local repl_start = 0
    for _, s in ipairs(segments) do
      repl_start = repl_start + #s
    end

    segments[#segments + 1] = m.replacement
    local repl_end = repl_start + #m.replacement

    highlights[#highlights + 1] = {
      col_start = repl_start,
      col_end = repl_end,
    }
    last_end = m.me
  end

  -- Remainder of the line after the last match
  segments[#segments + 1] = line:sub(last_end + 1)

  return table.concat(segments), highlights
end

-- }}}1
-------------------------------------------------------------------------------
-- Preview callback {{{1
-------------------------------------------------------------------------------

local function preview_subvert(opts, preview_ns, preview_buf)
  local bang = opts.bang
  local raw_args = opts.args
  local count = opts.range == 0 and 0 or 2
  local line1 = opts.line1
  local line2 = opts.line2

  local ok_parse, parsed =
    pcall(parse_subvert_args, bang, count, raw_args)
  if not ok_parse or parsed.mode ~= "substitute" then
    return 0
  end

  local parts = parsed.parts
  if #parts < 2 then
    return 0
  end

  local bad = parts[1]
  local good = parts[2]
  local flags = parts[3] or ""

  if bad == "" then
    return 0
  end

  local ok_n, norm = pcall(normalize_options, flags)
  if not ok_n then
    return 0
  end
  local ok_d, dict = pcall(create_dictionary, bad, good, norm)
  if not ok_d then
    return 0
  end

  local pat = build_pattern(dict, norm.boundaries)
  M._last_dict = dict

  local buf = vim.api.nvim_get_current_buf()
  local start_line, end_line
  if count == 0 then
    start_line = 1
    end_line = vim.api.nvim_buf_line_count(buf)
  else
    start_line = line1
    end_line = line2
  end

  local use_g = norm.flags:find("g") ~= nil
  local has_matches = false
  local preview_lines = {}

  for lnum = start_line, end_line do
    local lines =
      vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)
    local line = lines[1]
    if not line then
      break
    end

    local matches = collect_line_matches(line, pat, dict, use_g)
    if #matches > 0 then
      has_matches = true
      local new_line, highlights = build_replaced_line(line, matches)

      -- Replace the line in the buffer so the user sees the result.
      -- Neovim snapshots before calling us and reverts afterwards.
      vim.api.nvim_buf_set_lines(
        buf,
        lnum - 1,
        lnum,
        false,
        { new_line }
      )

      -- Now highlight each replacement span on the *new* line.
      for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_set_extmark(buf, preview_ns, lnum - 1, hl.col_start, {
          end_col = hl.col_end,
          hl_group = "Substitute",
        })
      end

      if preview_buf and preview_buf >= 0 then
        preview_lines[#preview_lines + 1] =
          string.format("|%d| %s", lnum, new_line)
      end
    end
  end

  if not has_matches then
    return 0
  end

  if preview_buf and preview_buf >= 0 and #preview_lines > 0 then
    vim.api.nvim_buf_set_lines(
      preview_buf,
      0,
      -1,
      false,
      preview_lines
    )
    return 2
  end

  return 1
end

-- }}}1
-------------------------------------------------------------------------------
-- Setup {{{1
-------------------------------------------------------------------------------

function M.setup(user_opts)
  user_opts = user_opts or {}

  local cmd_opts = {
    nargs = 1,
    bang = true,
    bar = true,
    range = true,
    addr = "lines",
    complete = function(arglead, _cmdline, _cursorpos)
      if arglead:match("^[^/?%-]") then
        local words = {}
        local seen = {}
        for lnum = vim.fn.line("w0"), vim.fn.line("w$") do
          local line = vim.fn.getline(lnum)
          for w in line:gmatch("%f[%w_][%w_][%w_]+%f[^%w_]") do
            if not seen[w] then
              seen[w] = true
              words[#words + 1] = w
            end
          end
        end
        table.sort(words)
        return words
      end
      return {}
    end,
    preview = preview_subvert,
  }

  vim.api.nvim_create_user_command("Subvert", function(o)
    execute_subvert(o.bang, o.line1, o.line2, o.range, o.args)
  end, cmd_opts)

  local has_S = false
  pcall(function()
    local info = vim.api.nvim_parse_cmd("S test", {})
    if info and info.cmd and info.cmd ~= "Subvert" then
      has_S = true
    end
  end)
  if not has_S then
    vim.api.nvim_create_user_command("S", function(o)
      execute_subvert(o.bang, o.line1, o.line2, o.range, o.args)
    end, cmd_opts)
  end
end

-- }}}1

return M
