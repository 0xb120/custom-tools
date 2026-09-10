#!/usr/bin/env bash
# PostToolUse(Write|Edit) hook — enforce the report-formatting rules from
# AGENTS.md (§ Report formatting) on report files:
#   1. Prose is copy-paste-ready: never hard-wrapped mid-sentence. One paragraph
#      = one continuous line; the renderer wraps it. Hard newlines belong only
#      between block elements.
#   2. Every fenced code block opens with a language (```sh, ```http, ```json),
#      and no fence line is indented or tab-ed — an indented fence turns into an
#      indented-code block or nests inside the surrounding list, which breaks
#      copy-paste and the report renderer.
#
# Scope: *.md under findings/ and the root-level <activity>.md (identified by
# its db:render markers, not by name). Working files — journal.md, TODO.md,
# AGENTS.md, the _template.md / finding.md reference — are exempt.
#
# Detection: a "hard-wrapped paragraph" is a run of 2+ consecutive lines that
# are all flowing prose — i.e. with no blank line, heading, list marker, table
# row, blockquote, code fence, horizontal rule, HTML/marker line, or `Label:` /
# `**Label**:` definition line breaking them apart. That run IS the violation.
# A fence violation is a ``` line with leading whitespace, or an *opening* fence
# whose info string is empty (the closing fence never carries a language).
#
# Exit 2 with the offending line numbers so Claude fixes the file. Exit 0 when
# the file is clean or out of scope.

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

# One pass, two classes of violation, tagged so the report can explain each.
report="$(awk '
function flush(){ if (count >= 2) printf "wrap\t  lines %d-%d\n", start, last; count=0; start=0; last=0 }
BEGIN { incode=0 }
{
    if ($0 ~ /^[[:space:]]*```/) {                                                 # code fence
        flush()
        if ($0 ~ /^[[:space:]]/)
            printf "fence\t  line %d: indented code fence\n", NR
        if (!incode) {
            info = $0
            sub(/^[[:space:]]*`+/, "", info)
            sub(/[[:space:]]+$/, "", info)
            if (info == "")
                printf "fence\t  line %d: code fence without a language\n", NR
        }
        incode = !incode
        next
    }
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

[ -z "$report" ] && exit 0

wrapped="$(printf '%s\n' "$report" | awk -F'\t' '$1=="wrap"{print $2}')"
fences="$(printf '%s\n'  "$report" | awk -F'\t' '$1=="fence"{print $2}')"

{
    echo "Report-formatting violation in ${file}:"
    if [ -n "$wrapped" ]; then
        echo "Hard-wrapped prose:"
        echo "$wrapped"
    fi
    if [ -n "$fences" ]; then
        echo "Code blocks:"
        echo "$fences"
    fi
    echo
    if [ -n "$wrapped" ]; then
        echo "AGENTS.md (§ Report formatting): report prose must be copy-paste-ready"
        echo "and must NEVER be hard-wrapped mid-sentence. Rewrite each flagged"
        echo "paragraph as ONE continuous line — keep newlines only between"
        echo "paragraphs, list items, and table rows."
    fi
    if [ -n "$fences" ]; then
        [ -n "$wrapped" ] && echo
        echo "AGENTS.md (§ Report formatting): every fenced code block must open with"
        echo "a language (\`\`\`sh, \`\`\`http, \`\`\`json, \`\`\`text when nothing fits) and no"
        echo "fence line may be indented or tab-ed — start every \`\`\` at column 0,"
        echo "including inside a numbered reproduction step."
    fi
} >&2
exit 2
