-- Neovim compiler file for the Odin programming language
-- Language: Odin (https://odin-lang.org)

if vim.b.current_compiler ~= nil then
  return
end
vim.b.current_compiler = "odin"

-- Default to `odin check` on the current file's directory.
-- Override per-project with: `:CompilerSet makeprg=odin\ build\ .\ -vet`
vim.bo.makeprg = "odin build . -vet -strict-style"

-- Odin error format examples:
--   C:\path\to\file.odin(12:5) Error: Something went wrong
--   /path/to/file.odin(34:7) Syntax Error: Unexpected token
-- Warnings use the same shape but with "Warning:" instead of "Error:".
vim.bo.errorformat = table.concat({
  "%f(%l:%c) %trror: %m",
  "%f(%l:%c) Syntax %trror: %m",
  "%f(%l:%c) %tarning: %m",
  "%f(%l:%c) Syntax %tarning: %m",
  -- Fallbacks without a column
  "%f(%l) %trror: %m",
  "%f(%l) %tarning: %m",
  -- Generic catch-all for lines Odin emits without severity
  "%f(%l:%c) %m",
}, ",")
