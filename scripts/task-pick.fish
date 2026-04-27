source (dirname (status -f))/task-lib.fish

function task-pick --description "Interactive picker for tmux panes (priority: expedi worktrees) with jump/send/less/kill actions"
    set -l mode fzf
    for arg in $argv
        switch $arg
            case --tui
                set mode tui
            case --fzf
                set mode fzf
            case -h --help
                echo "task-pick [--tui]"
                echo "  (default)  fzf single-shot picker"
                echo "  --tui      full-screen live-refresh TUI"
                echo "Keys (fzf):  enter=jump  ctrl-y=send 1↵  ctrl-l=less  ctrl-x=kill  ctrl-t=tui  ctrl-r=refresh"
                echo "Keys (tui):  j/k move  enter=jump  y=send 1↵  l=less  x=kill  f=fzf  r=refresh  q=quit"
                return 0
        end
    end

    if not set -q TMUX
        echo "task-pick: not inside tmux" >&2
        return 1
    end

    if test "$mode" = tui
        _tp_tui
    else
        _tp_fzf_loop
    end
end

# --- Row collection / formatting --------------------------------------------

# Sorted rows ready for display. Tab-separated:
#   1=pane_id  2=window_index  3=pane_index  4=display_line
function _tp_collect
    set -l rows
    for row in (_tm_pane_rows)
        set rows $rows $row
    end
    if test (count $rows) -eq 0
        return 0
    end

    # Sort rows by tier asc, then age_seconds asc (newer prompts first).
    # Use printf piped to sort -k1n -k13n with tab delimiter.
    set -l sorted (printf '%s\n' $rows | sort -t \t -k1,1n -k13,13n)

    set -l max_name 0
    for r in $sorted
        set -l p (string split \t -- $r)
        set -l n (string length -- $p[5])
        test $n -gt $max_name; and set max_name $n
    end
    test $max_name -lt 16; and set max_name 16
    test $max_name -gt 32; and set max_name 32

    for r in $sorted
        set -l p (string split \t -- $r)
        set -l tier $p[1]; set -l pid $p[2]; set -l widx $p[3]; set -l pidx $p[4]
        set -l name $p[5]; set -l state $p[8]; set -l age $p[9]; set -l hint $p[10]
        set -l is_expedi $p[12]

        set -l glyph
        switch $state
            case awaiting-input;        set glyph '!'
            case working;               set glyph '●'
            case interrupted;           set glyph '✗'
            case idle
                if test $tier = 5
                    set glyph '·'
                else
                    set glyph '○'
                end
            case done;                  set glyph '✓'
            case '*';                   set glyph '·'
        end

        set -l e_tag '[ ]'
        test "$is_expedi" = 1; and set e_tag '[E]'

        set -l name_short (string sub -l $max_name -- $name)
        set -l winpos (printf '%s:%s' $widx $pidx)

        set -l tail
        if test "$state" = awaiting-input -a "$hint" != '-'
            set tail $hint
        else
            set tail $state
        end

        set -l age_disp $age
        test "$age" = '-'; and set age_disp ''

        set -l display (printf '%s %s %4s %-'$max_name's %4s  %s' \
            $glyph $e_tag $winpos $name_short $age_disp $tail)

        printf '%s\t%s\t%s\t%s\n' $pid $widx $pidx $display
    end
end

# --- Actions ---------------------------------------------------------------

function _tp_jump --argument-names pane_id widx
    set -l session (tmux display-message -p '#S')
    tmux select-window -t "$session:$widx" 2>/dev/null
    tmux select-pane -t $pane_id 2>/dev/null
end

function _tp_send_one --argument-names pane_id
    tmux send-keys -t $pane_id '1' Enter
end

function _tp_less --argument-names pane_id
    tmux capture-pane -p -S -2000 -t $pane_id 2>/dev/null | less -R
end

function _tp_kill --argument-names pane_id
    read -P "kill pane $pane_id? [y/N] " -l ans
    if test "$ans" = y -o "$ans" = Y
        tmux kill-pane -t $pane_id
        echo "killed $pane_id"
    end
end

# --- fzf loop --------------------------------------------------------------

function _tp_fzf_loop
    while true
        set -l lines (_tp_collect)
        if test (count $lines) -eq 0
            echo "task-pick: no panes" >&2
            return 0
        end

        set -l out (printf '%s\n' $lines | fzf \
            --no-sort \
            --delimiter=\t \
            --with-nth=4 \
            --header='enter=jump  ctrl-y=send 1↵  ctrl-l=less  ctrl-x=kill  ctrl-t=tui  ctrl-r=refresh' \
            --preview='tmux capture-pane -p -S -80 -t {1}' \
            --preview-window='right:55%:wrap' \
            --expect=ctrl-y,ctrl-l,ctrl-x,ctrl-t,ctrl-r 2>/dev/null)

        if test (count $out) -eq 0
            return 0
        end

        set -l key $out[1]
        set -l sel
        if test (count $out) -ge 2
            set sel $out[2]
        end

        if test "$key" = ctrl-r
            continue
        end

        if test -z "$sel"
            return 0
        end

        set -l fields (string split \t -- $sel)
        set -l pid $fields[1]
        set -l widx $fields[2]

        switch $key
            case ''
                _tp_jump $pid $widx
                return 0
            case ctrl-y
                _tp_send_one $pid
                return 0
            case ctrl-l
                _tp_less $pid
                continue
            case ctrl-x
                _tp_kill $pid
                continue
            case ctrl-t
                _tp_tui
                return 0
        end
    end
end

# --- TUI mode --------------------------------------------------------------

function _tp_tui
    set -l idx 1
    set -l lines
    set -l running 1

    function __tp_tui_cleanup
        tput cnorm 2>/dev/null
        tput sgr0 2>/dev/null
    end

    tput civis 2>/dev/null

    while test $running = 1
        set lines (_tp_collect)
        set -l n (count $lines)
        if test $n -eq 0
            tput clear 2>/dev/null; or printf '\033[2J\033[H'
            echo "(no cc panes; press q)"
            read -n 1 -t 2 -l key
            if test "$key" = q
                set running 0
            end
            continue
        end

        test $idx -lt 1; and set idx 1
        test $idx -gt $n; and set idx $n

        tput clear 2>/dev/null; or printf '\033[2J\033[H'
        echo "task-pick — j/k move  enter=jump  y=send 1↵  l=less  x=kill  f=fzf  r=refresh  q=quit"
        echo
        for i in (seq $n)
            set -l fields (string split \t -- $lines[$i])
            set -l display $fields[4]
            if test $i = $idx
                tput rev 2>/dev/null
                printf '> %s' $display
                tput sgr0 2>/dev/null
                printf '\n'
            else
                printf '  %s\n' $display
            end
        end

        read -n 1 -t 2 -l key
        if test -z "$key"
            continue
        end

        switch $key
            case j
                set idx (math $idx + 1)
            case k
                set idx (math $idx - 1)
            case q
                set running 0
            case r
                # force redraw on next loop
            case f
                __tp_tui_cleanup
                _tp_fzf_loop
                set running 0
            case ''
                # enter
                set -l fields (string split \t -- $lines[$idx])
                __tp_tui_cleanup
                _tp_jump $fields[1] $fields[2]
                set running 0
            case y
                set -l fields (string split \t -- $lines[$idx])
                _tp_send_one $fields[1]
            case l
                set -l fields (string split \t -- $lines[$idx])
                __tp_tui_cleanup
                _tp_less $fields[1]
                tput civis 2>/dev/null
            case x
                set -l fields (string split \t -- $lines[$idx])
                __tp_tui_cleanup
                _tp_kill $fields[1]
                tput civis 2>/dev/null
        end
    end

    __tp_tui_cleanup
    functions -e __tp_tui_cleanup 2>/dev/null
end
