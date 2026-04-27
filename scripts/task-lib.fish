# Shared helpers for task-monitor / task-pick.
# Source from a fish script: `source ~/utensili/taskestro/scripts/task-lib.fish`.

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

# Age in seconds for sorting. '-' returns 99999999.
function _tm_age_seconds --argument-names pane_id
    set -l cache_dir "$HOME/.cache/cc-monitor"
    set -l key (string replace -a / _ -- (string replace -a '%' _ -- $pane_id))
    set -l f "$cache_dir/$key.json"
    if not test -f $f
        echo 99999999
        return
    end
    set -l ts
    if command -q jq
        set ts (jq -r '.ts // empty' < $f 2>/dev/null)
    else
        set ts (string match -r '"ts"[[:space:]]*:[[:space:]]*([0-9]+)' -- (cat $f) | tail -1)
    end
    if test -z "$ts"
        echo 99999999
        return
    end
    math (date +%s) - $ts
end

# Emit one tab-separated row per pane in the current tmux session.
# Columns:
#   1=tier  2=pane_id  3=window_index  4=pane_index  5=window_name
#   6=cwd   7=pcmd     8=state         9=age         10=hint
#   11=branch_or_dash  12=is_expedi(0|1)  13=age_seconds
# Tiers:
#   1 expedi awaiting-input
#   2 expedi working/interrupted
#   3 expedi idle/done
#   4 cc outside expedi (claude|node, or non-idle/done state)
#   5 plain shell
function _tm_pane_rows
    set -l session (tmux display-message -p '#S')
    set -l panes (tmux list-panes -t "$session" -s \
        -F '#{window_index}'\t'#{pane_index}'\t'#{window_name}'\t'#{pane_current_path}'\t'#{pane_id}'\t'#{pane_current_command}' 2>/dev/null)

    for line in $panes
        set -l parts (string split \t -- $line)
        set -l widx $parts[1]
        set -l pidx $parts[2]
        set -l wname $parts[3]
        set -l cwd $parts[4]
        set -l pid $parts[5]
        set -l pcmd $parts[6]

        if test "$wname" = monitor
            continue
        end

        set -l target "$session:$widx.$pidx"
        set -l state (_tm_classify $target $pcmd)
        set -l hint (_tm_hint $target $state)
        set -l age (_tm_age $pid $state)
        set -l age_s (_tm_age_seconds $pid)

        set -l is_expedi 0
        set -l branch '-'
        if string match -q '*/.worktrees/*' -- $cwd
            or string match -q '*/worktrees/wt-*' -- $cwd
            set is_expedi 1
            set branch (string replace -r '.*/\.?worktrees/' '' -- $cwd)
        end

        set -l is_cc 0
        if test "$pcmd" = claude -o "$pcmd" = node
            set is_cc 1
        else if test "$state" != idle -a "$state" != done
            set is_cc 1
        end

        set -l tier 5
        if test $is_expedi = 1
            switch $state
                case awaiting-input;            set tier 1
                case working interrupted;       set tier 2
                case '*';                       set tier 3
            end
        else if test $is_cc = 1
            set tier 4
        end

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            $tier $pid $widx $pidx $wname $cwd $pcmd $state $age $hint $branch $is_expedi $age_s
    end
end
