let s:save_cpo = &cpoptions
set cpoptions&vim

let g:highlightedundo#highlight_mode = get(g:, 'highlightedundo#highlight_mode', 1)
let g:highlightedundo#highlight_duration_delete = get(g:, 'highlightedundo#highlight_duration_delete', 200)
let g:highlightedundo#highlight_duration_add = get(g:, 'highlightedundo#highlight_duration_add', 500)
let g:highlightedundo#highlight_extra_lines = get(g:, 'highlightedundo#highlight_extra_lines', &lines)

let s:TEMPBEFORE = ''
let s:TEMPAFTER = ''
let s:GUI_RUNNING = has('gui_running')

let s:highlights = []

function! highlightedundo#undo() abort "{{{
  let [n, _] = s:undoablecount()
  let safecount = min([v:count1, n])
  call s:common(safecount, 'u', "\<C-r>")
endfunction "}}}
function! highlightedundo#redo() abort "{{{
  let [_, n] = s:undoablecount()
  let safecount = min([v:count1, n])
  call s:common(safecount, "\<C-r>", 'u')
endfunction "}}}
function! highlightedundo#Undo() abort "{{{
  call s:common(1, 'U', 'U')
endfunction "}}}
function! highlightedundo#gminus() abort "{{{
  let undotree = undotree()
  let safecount = min([v:count1, undotree.seq_cur + 1])
  call s:common(safecount, 'g-', 'g+')
endfunction "}}}
function! highlightedundo#gplus() abort "{{{
  let undotree = undotree()
  let safecount = min([v:count1, undotree.seq_last - undotree.seq_cur])
  call s:common(safecount, 'g+', 'g-')
endfunction "}}}
function! s:common(count, command, countercommand) abort "{{{
  if a:count <= 0
    return
  endif

  let view = winsaveview()
  let countstr = a:count == 1 ? '' : string(a:count)
  let before = getline(1, '$')
  let [start_before, end_before] = s:highlight_range(g:highlightedundo#highlight_extra_lines)
  execute 'silent noautocmd normal! ' . countstr . a:command
  let after = getline(1, '$')
  let [start_after, end_after] = s:highlight_range(g:highlightedundo#highlight_extra_lines)
  try
    let diffoutput = s:calldiff(before, after)
  finally
    if a:countercommand !=# ''
      execute 'silent noautocmd normal! ' . countstr . a:countercommand
    endif
    call winrestview(view)
  endtry
  let difflist = s:parsediff(diffoutput, start_before, end_before, start_after, end_after)

  let originalcursor = s:hidecursor()
  try
    call s:quench_highlight()
    call s:blink(difflist, g:highlightedundo#highlight_duration_delete)
    execute "silent normal! " . a:count . a:command
    call s:glow(difflist, g:highlightedundo#highlight_duration_add)
  finally
    call s:restorecursor(originalcursor)
  endtry
endfunction "}}}
function! s:highlight_range(extra_lines) abort "{{{
  let highlight_start = max([1, line('w0') - a:extra_lines])
  let highlight_end = min([line('$'), line('w$') + a:extra_lines])
  return [highlight_start, highlight_end]
endfunction "}}}
function! s:hidecursor() abort "{{{
  if s:GUI_RUNNING
    let cursor = &guicursor
    set guicursor+=n-o:block-NONE
  else
    let cursor = &t_ve
    set t_ve=
  endif
  return cursor
endfunction "}}}
function! s:restorecursor(originalcursor) abort "{{{
  if s:GUI_RUNNING
    set guicursor&
    let &guicursor = a:originalcursor
  else
    let &t_ve = a:originalcursor
  endif
endfunction "}}}

" for debug
function! highlightedundo#dumptree(filename) abort "{{{
  call writefile([string(undotree())], a:filename)
endfunction "}}}

" Region class "{{{
let s:region = {
  \   '__class__': 'Region',
  \   'head': [0, 0, 0, 0],
  \   'tail': [0, 0, 0, 0],
  \   'wise': 'v'
  \ }
function! s:Region(head, tail, wise) abort
  let region = deepcopy(s:region)
  let region.head = a:head
  let region.tail = a:tail
  let region.wise = a:wise
  return region
endfunction "}}}
" Subdiff class "{{{
let s:subdiff = {
  \   '__class__': 'Subdiff',
  \   'region': deepcopy(s:region),
  \   'lines': [],
  \ }
function! s:Subdiff(head, tail, type, lines) abort
  let subdiff = deepcopy(s:subdiff)
  let subdiff.region = s:Region(a:head, a:tail, a:type)
  let subdiff.lines = a:lines
  return subdiff
endfunction "}}}
" Diff class "{{{
let s:diff = {
  \   '__class__': 'Diff',
  \   'kind': '',
  \   'add': [],
  \   'delete': [],
  \ }
function! s:Diff(kind, delete_lines, add_lines) abort
  let diff = deepcopy(s:diff)
  let diff.kind = a:kind
  if a:kind ==# 'a'
    let startline = a:add_lines[0][0]
    let endline = a:add_lines[-1][0]
    let lines = map(copy(a:add_lines), 'v:val[1]')
    let addsubdiff = s:subdifflist_add(startline, endline, lines)
    call add(diff.add, addsubdiff)
  elseif a:kind ==# 'd'
    let startline = a:delete_lines[0][0]
    let endline = a:delete_lines[-1][0]
    let lines = map(copy(a:delete_lines), 'v:val[1]')
    let delsubdiff = s:subdifflist_delete(startline, endline, lines)
    call add(diff.delete, delsubdiff)
  elseif a:kind ==# 'c'
    let n_delete = len(a:delete_lines)
    let n_add = len(a:add_lines)
    let n = max([n_delete, n_add])
    for i in range(n)
      if i < n_delete && i < n_add
        let [fromlinenr, before] = a:delete_lines[i]
        let [tolinenr, after] = a:add_lines[i]
        let [delsubdiffs, addsubdiffs] = s:subdifflist_change(fromlinenr, tolinenr, before, after)
        call extend(diff.delete, delsubdiffs)
        call extend(diff.add, addsubdiffs)
      elseif i < n_delete
        let [fromlinenr, before] = a:delete_lines[i]
        let delsubdiff = s:subdifflist_delete(fromlinenr, fromlinenr, [before])
        call add(diff.delete, delsubdiff)
      elseif i < n_add
        let [tolinenr, after] = a:add_lines[i]
        let addsubdiff = s:subdifflist_add(tolinenr, tolinenr, [after])
        call add(diff.add, addsubdiff)
      endif
    endfor
  endif
  return diff
endfunction
function! s:subdifflist_delete(startline, endline, lines) abort "{{{
  let head = [0, a:startline, 1, 0]
  let tail = [0, a:endline, strlen(a:lines[-1]), 0]
  let subdiff = s:Subdiff(head, tail, 'V', a:lines)
  return subdiff
endfunction "}}}
function! s:subdifflist_add(startline, endline, lines) abort "{{{
  let head = [0, a:startline, 1, 0]
  let tail = [0, a:endline, strlen(a:lines[-1]), 0]
  let subdiff = s:Subdiff(head, tail, 'V', a:lines)
  return subdiff
endfunction "}}}
function! s:subdifflist_change(fromlinenr, tolinenr, before, after) abort "{{{
  let [changedbefore, changedafter] = s:getchanged(a:before, a:after)
  let [beforeindexes, afterindexes] = s:longestcommonsubsequence(
                                    \ changedbefore[0], changedafter[0])
  let delsubdiffs = s:splitchange(a:fromlinenr, changedbefore, beforeindexes)
  let addsubdiffs = s:splitchange(a:tolinenr, changedafter, afterindexes)
  return [delsubdiffs, addsubdiffs]
endfunction "}}}
"}}}
function! s:escape(string) abort  "{{{
  return escape(a:string, '~"\.^$[]*')
endfunction "}}}
" function! s:system(cmd) abort "{{{
if exists('*job_start')
  " NOTE: Arigatele...
  "       https://gist.github.com/mattn/566ba5fff15f947730f9c149e74f0eda
  function! s:system(cmd) abort
    let out = ''
    let job = job_start(a:cmd, {'out_cb': {ch,msg -> [execute('let out .= msg'), out]}, 'out_mode': 'raw'})
    while job_status(job) ==# 'run'
      sleep 1m
    endwhile
    return out
  endfunction
else
  function! s:system(cmd) abort
    return system(a:cmd)
  endfunction
endif
"}}}
function! s:undoablecount() abort "{{{
  let undotree = undotree()
  if undotree.entries == []
    return [0, 0]
  endif
  if undotree.seq_cur == 0
    let undocount = 0
    let redocount = len(undotree.entries)
    return [undocount, redocount]
  endif

  " get *correct* seq_cur
  let seq_cur = s:get_seq_of_curhead_parent(undotree)
  if seq_cur == 0
    return [0, 1]
  elseif seq_cur == -1
    let seq_cur = undotree.seq_cur
  endif

  let stack = []
  let parttree = {}
  let parttree.pos = [0]
  let parttree.tree = undotree.entries
  while 1
    let node = parttree.tree[parttree.pos[-1]]
    if node.seq == seq_cur
      break
    endif
    if has_key(node, 'alt')
      let alttree = {}
      let alttree.pos = parttree.pos + [0]
      let alttree.tree = node.alt
      call add(stack, alttree)
    endif
    let parttree.pos[-1] += 1
    if len(parttree.tree) <= parttree.pos[-1]
      if empty(stack)
        " shouldn't reach here
        let msg = [
          \   'highlightedundo: cannot find the current undo sequence!'
          \   'Could you :call highlightedundo#dumptree("~\undotree.txt") and'
          \   'report the dump file to <https://github.com/machakann/vim-highlightedundo/issues>'
          \   'if you do not mind? it does not include any buffer text.'
          \ ]
        echoerr join(msg)
      else
        let parttree = remove(stack, -1)
      endif
    endif
  endwhile
  let undocount = eval(join(parttree.pos, '+')) + 1
  let redocount = len(parttree.tree) - parttree.pos[-1] - 1
  return [undocount, redocount]
endfunction "}}}
function! s:get_seq_of_curhead_parent(undotree) abort "{{{
  if a:undotree.entries == []
    return -1
  endif
  let stack = []
  let parttree = {}
  let parttree.pos = [0]
  let parttree.tree = a:undotree.entries
  let node = {'seq': 0}
  while 1
    let parentnode = node
    let node = parttree.tree[parttree.pos[-1]]
    if has_key(node, 'curhead')
      return parentnode.seq
    endif
    if has_key(node, 'alt')
      let alttree = {}
      let alttree.pos = parttree.pos + [0]
      let alttree.tree = node.alt
      call add(stack, alttree)
    endif
    let parentnodepos = parttree.pos
    let parttree.pos[-1] += 1
    if len(parttree.tree) <= parttree.pos[-1]
      if empty(stack)
        break
      else
        let parttree = remove(stack, -1)
      endif
    endif
  endwhile
  return -1
endfunction "}}}
function! s:getchanged(before, after) abort "{{{
  if empty(a:before) || empty(a:after)
    let changedbefore = [a:before, 0, strlen(a:before)]
    let changedafter = [a:after, 0, strlen(a:after)]
    return [changedbefore, changedafter]
  endif

  let headpat = printf('\m\C^\%%[%s]', substitute(escape(a:before, '~"\.^$*'), '\([][]\)', '[\1]', 'g'))
  let start = matchend(a:after, headpat)
  if start == -1
    let start = 0
  endif

  let revbefore = join(reverse(split(a:before, '\zs')), '')
  let revafter = join(reverse(split(a:after, '\zs')), '')
  let tailpat = printf('\m\C^\%%[%s]', substitute(escape(revbefore, '~"\.^$*'), '\([][]\)', '[\1]', 'g'))
  let revend = matchend(revafter, tailpat)
  if revend == -1
    let revend = 0
  endif
  let end = strlen(a:after) - revend

  let commonhead = start == 0 ? '' : a:after[: start-1]
  let commontail = a:after[end :]
  let changedmask = printf('\m\C^%s\zs.*\ze%s$',
                         \ s:escape(commonhead), s:escape(commontail))
  let changedbefore = matchstrpos(a:before, changedmask)
  let changedafter = matchstrpos(a:after, changedmask)
  return [changedbefore, changedafter]
endfunction "}}}
function! s:splitchange(linenr, change, lcsindexes) abort "{{{
  " What I only can do for this func is just praying for my god so far...
  if empty(a:change[0])
    return []
  endif
  if empty(a:lcsindexes) || strchars(a:change[0]) == len(a:lcsindexes)
    let head = [0, a:linenr, a:change[1] + 1, 0]
    let tail = [0, a:linenr, a:change[2], 0]
    let subdiff = s:Subdiff(head, tail, 'v', [a:change[0]])
    return [subdiff]
  endif

  let charlist = split(a:change[0], '\zs')
  let indexes = range(len(charlist))
  call filter(indexes, '!count(a:lcsindexes, v:val)')

  let changes = []
  let columns = []
  for i in indexes
    let n = len(columns)
    if n == 0
      call add(columns, i)
    elseif n == 1
      if columns[-1] + 1 == i
        call add(columns, i)
      else
        call add(columns, columns[-1])
        call add(changes, columns)
        let columns = [i]
      endif
    else
      if columns[-1] + 1 == i
        let columns[-1] = i
      else
        call add(changes, columns)
        let columns = [i]
      endif
    endif
  endfor
  let n = len(columns)
  if n == 0
    " probably not possible
  elseif n == 1
    if columns[-1] + 1 == i
      call add(columns, i)
    else
      call add(columns, columns[-1])
    endif
  else
    if columns[-1] + 1 == i
      let columns[-1] = i
    endif
  endif
  call add(changes, columns)
  call map(changes, 's:charidx2idx(charlist, v:val)')
  call map(changes, 's:columns2subdiff(v:val, a:linenr, a:change)')
  return changes
endfunction "}}}
function! s:charidx2idx(charlist, columns) abort "{{{
  let indexes = [0, 0]
  if a:columns[0] != 0
    let indexes[0] = strlen(join(a:charlist[: a:columns[0] - 1], ''))
  endif
  if a:columns[1] != 0
    let indexes[1] = strlen(join(a:charlist[: a:columns[1]], '')) - 1
  endif
  return indexes
endfunction "}}}
function! s:columns2subdiff(columns, linenr, change) abort "{{{
  let text = a:change[0][a:columns[0] : a:columns[1]]
  let head = [0, a:linenr, a:change[1] + a:columns[0] + 1, 0]
  let tail = [0, a:linenr, a:change[1] + a:columns[1] + 1, 0]
  return s:Subdiff(head, tail, 'v', [text])
endfunction "}}}
function! s:calldiff(before, after) abort "{{{
  if s:TEMPBEFORE ==# ''
    let s:TEMPBEFORE = tempname()
    let s:TEMPAFTER = tempname()
  endif

  let ret1 = writefile(a:before, s:TEMPBEFORE)
  let ret2 = writefile(a:after, s:TEMPAFTER)
  if ret1 == -1 || ret2 == -1
    let s:TEMPBEFORE = ''
    let s:TEMPAFTER = ''
    echohl ErrorMsg
    echomsg 'highlightedundo: Failed to make tmp files.'
    echohl NONE
    return []
  endif

  let cmd = printf('diff -b "%s" "%s"', s:TEMPBEFORE, s:TEMPAFTER)
  let diff = split(s:system(cmd), '\r\?\n')
  return diff
endfunction "}}}
function! s:expandlinestr(linestr) abort "{{{
  let linenr = map(split(a:linestr, ','), 'str2nr(v:val)')
  if len(linenr) == 1
    let linenr = [linenr[0], linenr[0]]
  endif
  return linenr
endfunction "}}}
function! s:parsechunk(diffoutput, i, kind, fromlinenr, tolinenr, start_before, end_before, start_after, end_after) abort "{{{
  let i = a:i
  let add_lines = []
  let delete_lines = []
  " FIXME: This is not the best implementation, the range of for loop should
  "        be statistically determined.
  " XXX: For performance, check only up to 250 chars.
  if a:kind is# 'd' || a:kind is# 'c'
    for linenr in range(a:fromlinenr[0], a:fromlinenr[1])
      if a:start_before <= linenr && linenr <= a:end_before
        let line = a:diffoutput[i]
        let [deletedline, pos, _] = matchstrpos(line, '\m^<\s\zs.\{,250}')
        if pos != -1
          call add(delete_lines, [linenr, deletedline])
        endif
      endif
      let i += 1
    endfor
  endif

  " skip '---'
  if a:kind is# 'c'
    let i += 1
  endif

  if a:kind is# 'a' || a:kind is# 'c'
    for linenr in range(a:tolinenr[0], a:tolinenr[1])
      if a:start_after <= linenr && linenr <= a:end_after
        let line = a:diffoutput[i]
        let [addedline, pos, _] = matchstrpos(line, '\m^>\s\zs.\{,250}')
        if pos != -1
          call add(add_lines, [linenr, addedline])
        endif
      endif
      let i += 1
    endfor
  endif
  return [delete_lines, add_lines, i]
endfunction "}}}
function! s:parsediff(diffoutput, start_before, end_before, start_after, end_after) abort "{{{
  if a:diffoutput == []
    return []
  endif

  let parsed = []
  let n = len(a:diffoutput)
  let i = 0
  while i < n
    let line = a:diffoutput[i]
    let res = matchlist(line, '\m\C^\(\d\+\%(,\d\+\)\?\)\([acd]\)\(\d\+\%(,\d\+\)\?\)')
    if res == []
      continue
    endif
    let [whole, from, kind, to, _, _, _, _, _, _] = res
    let i += 1

    let fromlinenr = s:expandlinestr(from)
    let tolinenr = s:expandlinestr(to)
    let [delete_lines, add_lines, i] = s:parsechunk(
            \ a:diffoutput, i, kind, fromlinenr, tolinenr,
            \ a:start_before, a:end_before, a:start_after, a:end_after)
    let diff = s:Diff(kind, delete_lines, add_lines)
    call add(parsed, diff)
  endwhile
  return parsed
endfunction "}}}
function! s:waitforinput(duration) abort "{{{
  let clock = highlightedundo#clock#new()
  let c = 0
  call clock.start()
  while empty(c) || c == 128
    let c = getchar(1)
    if clock.started && clock.elapsed() > a:duration
      break
    endif
  endwhile
  call clock.stop()
endfunction "}}}
function! s:quench_highlight() abort "{{{
  for h in s:highlights
    call h.quench()
  endfor
  call filter(s:highlights, 0)
endfunction "}}}
function! s:blink(difflist, duration) abort "{{{
  if a:duration <= 0
    return
  endif
  if g:highlightedundo#highlight_mode < 2
    return
  endif

  let h = highlightedundo#highlight#new()
  for diff in a:difflist
    for subdiff in diff.delete
      if filter(copy(subdiff.lines), '!empty(v:val)') == []
        continue
      endif
      call h.add(subdiff.region)
    endfor
  endfor
  call h.show('HighlightedundoDelete')
  redraw

  try
    call s:waitforinput(a:duration)
  finally
    call h.quench()
  endtry
endfunction "}}}
function! s:glow(difflist, duration) abort "{{{
  if a:duration <= 0
    return
  endif
  if g:highlightedundo#highlight_mode < 1
    return
  endif

  let h = highlightedundo#highlight#new()
  let higroup = g:highlightedundo#highlight_mode == 1 ? 'HighlightedundoChange' : 'HighlightedundoAdd'
  for diff in a:difflist
    for subdiff in diff.add
      if filter(copy(subdiff.lines), '!empty(v:val)') == []
        continue
      endif
      call h.add(subdiff.region)
    endfor
  endfor
  call h.show(higroup)
  call h.quench_timer(a:duration)
  call add(s:highlights, h)
endfunction "}}}

" solving Longest Common Subsequence problem
function! s:lcsmap(n) abort "{{{
  let d = []
  for i in range(a:n)
    let d += [repeat([0], a:n)]
  endfor
  return d
endfunction
let s:dmax = 81
let s:lcsmap = s:lcsmap(s:dmax)
"}}}
function! s:longestcommonsubsequence(a, b) abort "{{{
  let a = split(a:a, '\zs')
  let b = split(a:b, '\zs')
  let na = len(a)
  let nb = len(b)
  if na == 0 || nb == 0
    return [[], []]
  endif
  if na == 1
    return s:lcs_for_a_char(a:a, a:b)
  endif
  if nb == 1
    return s:lcs_for_a_char(a:b, a:a)
  endif

  let nmax = max([na, nb])
  if nmax >= s:dmax
    let s:dmax = nmax + 1
    let s:lcsmap = s:lcsmap(s:dmax)
  endif
  let d = copy(s:lcsmap)
  for i in range(1, na)
    for j in range(1, nb)
      if a[i - 1] ==# b[j - 1]
        let d[i][j] = d[i - 1][j - 1] + 1
      else
        let d[i][j] = max([d[i - 1][j], d[i][j - 1]])
      endif
    endfor
  endfor
  return s:backtrack(d, a, b, na, nb)
endfunction "}}}
function! s:lcs_for_a_char(a, b) abort "{{{
  let commonindex = stridx(a:b, a:a)
  if commonindex == -1
    let aindexes = []
    let bindexes = []
  else
    let aindexes = [0]
    let bindexes = [commonindex]
  endif
  return [aindexes, bindexes]
endfunction "}}}
function! s:backtrack(d, a, b, na, nb) abort "{{{
  let aindexes = []
  let bindexes = []
  let i = a:na
  let j = a:nb
  while i != 0 && j != 0
    if a:a[i - 1] ==# a:b[j - 1]
      let i -= 1
      let j -= 1
      call add(aindexes, i)
      call add(bindexes, j)
    elseif a:d[i - 1][j] >= a:d[i][j - 1]
      let i -= 1
    else
      let j -= 1
    endif
  endwhile
  return [reverse(aindexes), reverse(bindexes)]
endfunction "}}}

let &cpoptions = s:save_cpo
unlet s:save_cpo

" vim:set foldmethod=marker:
" vim:set commentstring="%s:
" vim:set ts=2 sts=2 sw=2:
