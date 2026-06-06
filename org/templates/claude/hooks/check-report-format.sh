#!/usr/bin/env bash
# PostToolUse(Write|Edit) hook — enforce the "copy-paste-ready prose" rule from
# AGENT.md (§ Prose formatting) on report files: report prose must never be
# hard-wrapped mid-sentence. One paragraph = one continuous line; the renderer
# wraps it. Hard newlines belong only between block elements.
#
# Scope: *.md under findings/ and the root-level <activity>.md (identified by
# its db:render markers, not by name). Working files — journal.md, TODO.md,
# AGENT.md, the _template.md / finding.md reference — are exempt.
#
# Detection: a "hard-wrapped paragraph" is a run of 2+ consecutive lines that
# are all flowing prose — i.e. with no blank line, heading, list marker, table
# row, blockquote, code fence, horizontal rule, HTML/marker line, or `Label:` /
# `**Label**:` definition line breaking them apart. That run IS the violation.
#
# Exit 2 with the offending line ranges so Claude rewrites the paragraph onto a
# single line. Exit 0 when the file is clean or out of scope.

INPUT="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0

file="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

case "$file" in
    *.md) ;;
    *) exit 0 ;;
esac

# Never lint the untouched reference templates.
case "$file" in
    */_template.md|*/finding.md) exit 0 ;;
esac

# In scope only for report prose: a file under findings/, or the root
# <activity>.md (the only .md carrying the db:render markers).
in_scope=0
case "$file" in
    */findings/*.md|findings/*.md) in_scope=1 ;;
esac
if [ "$in_scope" -eq 0 ] && grep -qF '<!-- db:render' "$file" 2>/dev/null; then
    in_scope=1
fi
[ "$in_scope" -eq 0 ] && exit 0

ranges="$(awk '
function flush(){ if (count >= 2) printf "  lines %d-%d\n", start, last; count=0; start=0; last=0 }
BEGIN { incode=0 }
{
    if ($0 ~ /^[[:space:]]*```/)                                  { flush(); incode=!incode; next }  # code fence
    if (incode)                                                  { next }
    if ($0 ~ /^[[:space:]]*$/)                                   { flush(); next }  # blank
    if ($0 ~ /^[[:space:]]*#/)                                   { flush(); next }  # heading
    if ($0 ~ /^[[:space:]]*[-*+][[:space:]]/)                    { flush(); next }  # bullet
    if ($0 ~ /^[[:space:]]*[0-9]+[.)][[:space:]]/)               { flush(); next }  # numbered
    if ($0 ~ /^[[:space:]]*>/)                                   { flush(); next }  # blockquote
    if (index($0, "|") > 0)                                      { flush(); next }  # table row
    if ($0 ~ /^[[:space:]]*<!--/ || $0 ~ /-->[[:space:]]*$/)     { flush(); next }  # html / markers
    if ($0 ~ /^[[:space:]]*(-{3,}|={3,})[[:space:]]*$/)          { flush(); next }  # horizontal rule
    if ($0 ~ /^[[:space:]]*\*{0,2}[A-Za-z][A-Za-z0-9 _\/()-]*\*{0,2}:[[:space:]]/) { flush(); next }  # Label: value
    if (start == 0) start = NR
    count++; last = NR
}
END { flush() }
' "$file")"

[ -z "$ranges" ] && exit 0

{
    echo "Report-formatting violation in ${file}:"
    echo "$ranges"
    echo
    echo "AGENT.md (§ Prose formatting): report prose must be copy-paste-ready and"
    echo "must NEVER be hard-wrapped mid-sentence. Rewrite each flagged paragraph as"
    echo "ONE continuous line — keep newlines only between paragraphs, list items,"
    echo "and table rows."
} >&2
exit 2
