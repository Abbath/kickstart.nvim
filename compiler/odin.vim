
if exists('current_compiler')
  finish
endif

let s:save_cpo = &cpo
set cpo&vim

CompilerSet makeprg=odin\ build\ .
CompilerSet errorformat=%f(%l:%c)\ %m

let &cpo= s:save_cpo
unlet s:save_cpo
