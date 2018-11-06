scriptencoding utf-8
" Author: w0rp <devw0rp@gmail.com>
" Author: João Paulo S. de Souza <joao.paulo.silvasouza@hotmail.com>
" Description: Echoes lint message for the current line, if any

" Controls the milliseconds delay before echoing a message.
let g:ale_echo_delay = get(g:, 'ale_echo_delay', 10)
" A string format for the echoed message.
let g:ale_echo_msg_format = get(g:, 'ale_echo_msg_format', '%code: %%s')

let s:cursor_timer = -1
let s:last_pos = [0, 0, 0]

function! ale#cursor#TruncatedEcho(original_message) abort
    let l:message = a:original_message
    " Change tabs to spaces.
    let l:message = substitute(l:message, "\t", ' ', 'g')
    " Remove any newlines in the message.
    let l:message = substitute(l:message, "\n", '', 'g')

    " We need to remember the setting for shortmess and reset it again.
    let l:shortmess_options = &l:shortmess

    try
        let l:cursor_position = getcurpos()

        " The message is truncated and saved to the history.
        setlocal shortmess+=T

        try
            exec "norm! :echomsg l:message\n"
        catch /^Vim\%((\a\+)\)\=:E523/
            " Fallback into manual truncate (#1987)
            let l:winwidth = winwidth(0)

            if l:winwidth < strdisplaywidth(l:message)
                " Truncate message longer than window width with trailing '...'
                let l:message = l:message[:l:winwidth - 4] . '...'
            endif

            exec 'echomsg l:message'
        endtry

        " Reset the cursor position if we moved off the end of the line.
        " Using :norm and :echomsg can move the cursor off the end of the
        " line.
        if l:cursor_position != getcurpos()
            call setpos('.', l:cursor_position)
        endif
    finally
        let &l:shortmess = l:shortmess_options
    endtry
endfunction

function! ale#cursor#ClearVirtualText() abort
    if !has('nvim-0.3.2')
        return
    endif

    let l:buffer = bufnr('')

    call nvim_buf_clear_highlight(l:buffer, 1000, 0, -1)
endfunction

function! ale#cursor#ShowVirtualText(message, hl_group) abort
    if !has('nvim-0.3.2')
        return
    endif

    let l:cursor_position = getcurpos()
    let l:line = line('.')
    let l:buffer = bufnr('')
    let l:prefix = get(g:, 'ale_virtualtext_prefix', '> ')

    call nvim_buf_set_virtual_text(l:buffer, 1000, l:line-1, [[l:prefix.a:message, a:hl_group]], {})
endfunction

function! s:FindItemAtCursor(buffer) abort
    let l:info = get(g:ale_buffer_info, a:buffer, {})
    let l:loclist = get(l:info, 'loclist', [])
    let l:pos = getcurpos()
    let l:index = ale#util#BinarySearch(l:loclist, a:buffer, l:pos[1], l:pos[2])
    let l:loc = l:index >= 0 ? l:loclist[l:index] : {}

    return [l:info, l:loc]
endfunction

function! s:StopCursorTimer() abort
    if s:cursor_timer != -1
        call timer_stop(s:cursor_timer)
        let s:cursor_timer = -1
    endif
endfunction

function! ale#cursor#EchoCursorWarning(...) abort
    let l:buffer = bufnr('')

    if !g:ale_echo_cursor && !g:ale_cursor_detail && !g:ale_virtualtext_cursor
        return
    endif

    " Only echo the warnings in normal mode, otherwise we will get problems.
    if mode(1) isnot# 'n'
        return
    endif

    if ale#ShouldDoNothing(l:buffer)
        return
    endif

    let [l:info, l:loc] = s:FindItemAtCursor(l:buffer)

    if g:ale_echo_cursor
        if !empty(l:loc)
            let l:format = ale#Var(l:buffer, 'echo_msg_format')
            let l:msg = ale#GetLocItemMessage(l:loc, l:format)
            call ale#cursor#TruncatedEcho(l:msg)
            let l:info.echoed = 1
        elseif get(l:info, 'echoed')
            " We'll only clear the echoed message when moving off errors once,
            " so we don't continually clear the echo line.
            execute 'echo'
            let l:info.echoed = 0
        endif
    endif

    if g:ale_cursor_detail
        if !empty(l:loc)
            call s:ShowCursorDetailForItem(l:loc, {'stay_here': 1})
        else
            call ale#preview#CloseIfTypeMatches('ale-preview')
        endif
    endif

    if g:ale_virtualtext_cursor
        call ale#cursor#ClearVirtualText()

        if !empty(l:loc)
            let l:msg = get(l:loc, 'detail', l:loc.text)
            let l:hl_group = 'ALEInfo'
            let l:type = get(l:loc, 'type', 'E')

            if l:type is# 'E'
                let l:hl_group = 'ALEError'
            elseif l:type is# 'W'
                let l:hl_group = 'ALEWarning'
            endif

            call ale#cursor#ShowVirtualText(l:msg, l:hl_group)
        endif
    endif
endfunction

function! ale#cursor#EchoCursorWarningWithDelay() abort
    let l:buffer = bufnr('')

    if !g:ale_echo_cursor && !g:ale_cursor_detail && !g:ale_virtualtext_cursor
        return
    endif

    " Only echo the warnings in normal mode, otherwise we will get problems.
    if mode(1) isnot# 'n'
        return
    endif

    call s:StopCursorTimer()

    let l:pos = getcurpos()[0:2]

    " Check the current buffer, line, and column number against the last
    " recorded position. If the position has actually changed, *then*
    " we should echo something. Otherwise we can end up doing processing
    " the echo message far too frequently.
    if l:pos != s:last_pos
        let l:delay = ale#Var(l:buffer, 'echo_delay')

        let s:last_pos = l:pos
        let s:cursor_timer = timer_start(
        \   l:delay,
        \   function('ale#cursor#EchoCursorWarning')
        \)
    endif
endfunction

function! s:ShowCursorDetailForItem(loc, options) abort
    let l:stay_here = get(a:options, 'stay_here', 0)

    let s:last_detailed_line = line('.')
    let l:message = get(a:loc, 'detail', a:loc.text)
    let l:lines = split(l:message, "\n")
    call ale#preview#Show(l:lines, {'stay_here': l:stay_here})

    " Clear the echo message if we manually displayed details.
    if !l:stay_here
        execute 'echo'
    endif
endfunction

function! ale#cursor#ShowCursorDetail() abort
    let l:buffer = bufnr('')

    " Only echo the warnings in normal mode, otherwise we will get problems.
    if mode() isnot# 'n'
        return
    endif

    if ale#ShouldDoNothing(l:buffer)
        return
    endif

    call s:StopCursorTimer()

    let [l:info, l:loc] = s:FindItemAtCursor(l:buffer)

    if !empty(l:loc)
        call s:ShowCursorDetailForItem(l:loc, {'stay_here': 0})
    endif
endfunction
