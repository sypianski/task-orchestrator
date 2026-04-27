source (dirname (status -f))/task-lib.fish

function task-monitor --description "Live dashboard for task-orchestrator: shows state of every dispatched Claude Code task in the current tmux session"
    set -l mode once
    for arg in $argv
        switch $arg
            case -w --watch
                set mode watch
            case --bar
                set mode bar
            case -h --help
                echo "task-monitor [-w|--watch | --bar]"
                echo "  (default)   single-shot table"
                echo "  -w/--watch  refresh every 2s until Ctrl-C"
                echo "  --bar       one-line status-bar summary"
                return 0
        end
    end

    if not set -q TMUX
        echo "task-monitor: not inside tmux" >&2
        return 1
    end

    switch $mode
        case watch
            while true
                tput clear 2>/dev/null; or printf '\033[2J\033[H'
                _tm_render table
                sleep 2
            end
        case bar
            _tm_render bar
        case '*'
            _tm_render table
    end
end

function _tm_render --argument-names kind
    set -l session (tmux display-message -p '#S')
    set -l rows_window
    set -l rows_widx
    set -l rows_state
    set -l rows_age
    set -l rows_hint

    for row in (_tm_pane_rows)
        set -l p (string split \t -- $row)
        # Filter to expedi worktree panes (tiers 1-3) only — preserves legacy semantics.
        test "$p[12]" = 1; or continue
        set rows_window $rows_window $p[5]
        set rows_widx   $rows_widx   $p[3]
        set rows_state  $rows_state  $p[8]
        set rows_age    $rows_age    $p[9]
        set rows_hint   $rows_hint   $p[10]
    end

    if test (count $rows_window) -eq 0
        if test "$kind" = bar
            printf '·\n'
        else
            set -l dim ''; set -l rst ''
            isatty stdout; and set dim (set_color brblack); and set rst (set_color normal)
            printf '%sno dispatched tasks in %s%s\n' $dim $session $rst
        end
        return 0
    end

    if test "$kind" = bar
        set -l n_wrk 0; set -l n_inp 0; set -l n_idle 0; set -l n_int 0; set -l n_done 0
        for s in $rows_state
            switch $s
                case working;        set n_wrk  (math $n_wrk + 1)
                case awaiting-input; set n_inp  (math $n_inp + 1)
                case interrupted;    set n_int  (math $n_int + 1)
                case idle;           set n_idle (math $n_idle + 1)
                case done;           set n_done (math $n_done + 1)
            end
        end
        set -l parts
        test $n_inp -gt 0;  and set parts $parts (printf '!%d' $n_inp)
        test $n_wrk -gt 0;  and set parts $parts (printf '●%d' $n_wrk)
        test $n_int -gt 0;  and set parts $parts (printf '✗%d' $n_int)
        test $n_idle -gt 0; and set parts $parts (printf '○%d' $n_idle)
        test $n_done -gt 0; and set parts $parts (printf '✓%d' $n_done)
        printf '%s\n' (string join ' ' $parts)
        return 0
    end

    set -l tty 0
    isatty stdout; and set tty 1

    set -l order
    for prio in awaiting-input working interrupted idle done
        for i in (seq (count $rows_state))
            test $rows_state[$i] = $prio; and set order $order $i
        end
    end

    set -l tw 16
    for i in $order
        set -l l (math (string length -- $rows_widx[$i]) + 1 + (string length -- $rows_window[$i]))
        test $l -gt $tw; and set tw $l
    end
    test $tw -gt 38; and set tw 38

    set -l dim ''; set -l rst ''; set -l hdr ''
    if test $tty = 1
        set dim (set_color brblack)
        set rst (set_color normal)
        set hdr (set_color -o brwhite)
    end

    printf '    %s%-'$tw's %-14s %4s  %s%s\n' $hdr TASK STATE AGE HINT $rst

    for i in $order
        set -l state $rows_state[$i]
        set -l glyph; set -l col; set -l label
        switch $state
            case awaiting-input; set glyph '!'; set col (set_color -o red);    set label 'awaiting-input'
            case working;        set glyph '●'; set col (set_color green);     set label 'working'
            case interrupted;    set glyph '✗'; set col (set_color magenta);   set label 'interrupted'
            case idle;           set glyph '○'; set col (set_color yellow);    set label 'idle'
            case done;           set glyph '✓'; set col (set_color brblack);   set label 'done'
        end
        set -l rst_l $rst
        set -l col_l $col
        set -l dim_l $dim
        if test $tty = 0
            set rst_l ''; set col_l ''; set dim_l ''
        end

        set -l task_full (printf '%s:%s' $rows_widx[$i] $rows_window[$i])
        set -l task (string sub -l $tw -- $task_full)
        set -l age $rows_age[$i]
        set -l hint (string sub -l 60 -- $rows_hint[$i])

        set -l age_out $age
        set -l hint_out $hint
        test "$age" = '-';  and set age_out $dim_l'—'$rst_l
        test "$hint" = '-'; and set hint_out $dim_l'—'$rst_l

        printf '  %s%s %-'$tw's %-14s%s %4s  %s\n' \
            $col_l $glyph $task $label $rst_l \
            $age_out $hint_out
    end
end
