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
    set -l rows_branch

    # Enumerate panes in current session. Tab-separated for safe splitting.
    set -l panes (tmux list-panes -t "$session" -s \
        -F '#{window_index}'\t'#{window_name}'\t'#{pane_current_path}'\t'#{pane_id}'\t'#{pane_current_command}' 2>/dev/null)

    for line in $panes
        set -l parts (string split \t -- $line)
        set -l widx $parts[1]
        set -l wname $parts[2]
        set -l cwd $parts[3]
        set -l pid $parts[4]
        set -l pcmd $parts[5]

        # Filter: task windows only. Match both the current convention
        # (`<project>/.worktrees/<slug>`) and the legacy sibling pattern
        # (`.../worktrees/wt-<slug>`).
        if not string match -q '*/.worktrees/*' -- $cwd
            and not string match -q '*/worktrees/wt-*' -- $cwd
            continue
        end
        # Skip the orchestrator monitor window
        if test "$wname" = monitor
            continue
        end

        set -l target "$session:$widx"
        set -l state (_tm_classify $target $pcmd)
        set -l hint (_tm_hint $target $state)
        set -l age (_tm_age $pid $state)
        set -l branch (string replace -r '.*/\.?worktrees/' '' -- $cwd)

        set rows_window $rows_window $wname
        set rows_widx $rows_widx $widx
        set rows_state $rows_state $state
        set rows_age $rows_age $age
        set rows_hint $rows_hint $hint
        set rows_branch $rows_branch $branch
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

    # Table mode — sort by priority: awaiting-input > working > interrupted > idle > done
    set -l tty 0
    isatty stdout; and set tty 1

    set -l order
    for prio in awaiting-input working interrupted idle done
        for i in (seq (count $rows_state))
            test $rows_state[$i] = $prio; and set order $order $i
        end
    end

    # Compute task-cell width: widest "N:name" (min 16, max 38)
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

    # Header — aligns with rows: "  " + glyph(1) + " " + task(tw) + " " + state(14) + " " + age(4) + "  " + hint
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

        # glyph + window-number-prefixed task (bold colored), then state, age, hint
        printf '  %s%s %-'$tw's %-14s%s %4s  %s\n' \
            $col_l $glyph $task $label $rst_l \
            $age_out $hint_out
    end
end

function _tm_classify --argument-names target pcmd
    set -l buf (tmux capture-pane -p -t $target -S -40 2>/dev/null | string collect)
    if test -z "$buf"
        echo idle
        return
    end
    if string match -qr 'Do you want to proceed\?|What should Claude do instead\?|❯ 1\. Yes|│ 1\. Yes|Do you want to make this edit|1\. Yes' -- $buf
        echo awaiting-input
        return
    end
    if string match -qr 'esc to interrupt|tokens.*esc to' -- $buf
        echo working
        return
    end
    if string match -qr 'Interrupted by user' -- $buf
        echo interrupted
        return
    end
    # If the shell is back (not running claude), treat as done
    if test "$pcmd" = fish -o "$pcmd" = bash -o "$pcmd" = zsh
        echo done
        return
    end
    echo idle
end

function _tm_hint --argument-names target state
    if test "$state" != awaiting-input
        if test "$state" = working
            echo 'esc to interrupt'
        else
            echo '-'
        end
        return
    end
    set -l buf (tmux capture-pane -p -t $target -S -30 2>/dev/null)
    set -l q (string match -r '(?:Do you want[^?]*\?|What should Claude do instead\?|Do you want to make this edit[^?]*\?)' -- $buf | head -1)
    if test -n "$q"
        echo $q
    else
        echo 'needs input'
    end
end

function _tm_age --argument-names pane_id state
    set -l cache_dir "$HOME/.cache/cc-monitor"
    # Match any cache file referencing this pane_id
    set -l key (string replace -a / _ -- (string replace -a '%' _ -- $pane_id))
    set -l f "$cache_dir/$key.json"
    if not test -f $f
        echo '-'
        return
    end
    set -l ts
    if command -q jq
        set ts (jq -r '.ts // empty' < $f 2>/dev/null)
    else
        set ts (string match -r '"ts"[[:space:]]*:[[:space:]]*([0-9]+)' -- (cat $f) | tail -1)
    end
    if test -z "$ts"
        echo '-'
        return
    end
    set -l now (date +%s)
    set -l delta (math $now - $ts)
    if test $delta -lt 60
        printf '%ds\n' $delta
    else if test $delta -lt 3600
        printf '%dm\n' (math -s0 $delta / 60)
    else
        printf '%dh\n' (math -s0 $delta / 3600)
    end
end
