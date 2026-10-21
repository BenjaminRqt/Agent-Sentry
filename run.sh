#!/usr/bin/env bash
# Agent Sentry : pour chaque projet actif de config.json, prend les nouvelles
# issues de prod au-dessus du seuil, fait corriger par Claude dans un worktree,
# pousse une branche sentry/<shortId> et ouvre une MR en Draft.
# DRY_RUN=1 : aucun push, aucune MR, aucun commentaire ; le diff est gardé.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"   # claude, depuis cron
cd "$(dirname "$0")"
ICI=$PWD
source "${AGENT_SENTRY_ENV:-$HOME/.config/agent-sentry/env}"
: "${SENTRY_TOKEN:?SENTRY_TOKEN manquant}" "${GITLAB_TOKEN:?GITLAB_TOKEN manquant}"
DRY=${DRY_RUN:-0}

mkdir -p etat logs
exec 9>etat/verrou
flock -n 9 || { echo "Un passage tourne déjà."; exit 0; }

c() { jq -r "$1" config.json; }
SENTRY=$(c .sentry_url); ORG=$(c .sentry_org); GITLAB=$(c .gitlab_url)
ENVT=$(c .environnement); FENETRE=$(c .fenetre); MAX=$(c .max_mr_par_passage)
SEUIL_EV=$(c .seuil_evenements); SEUIL_US=$(c .seuil_utilisateurs)

log() { echo "$(date '+%F %T') $*" | tee -a logs/agent.log; }
uri() { jq -rn --arg v "$1" '$v|@uri'; }
sentry() { curl -sfS -H "Authorization: Bearer $SENTRY_TOKEN" "$SENTRY/api/0/$1" "${@:2}"; }
gitlab() { curl -sfS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB/api/v4/$1" "${@:2}"; }
note_sentry() { [ "$DRY" = 1 ] || sentry "issues/$1/comments/" -X POST -H 'Content-Type: application/json' \
  -d "$(jq -n --arg t "$2" '{text: $t}')" >/dev/null || log "commentaire Sentry impossible ($1)"; }

nb_mr=0
while read -r projet; do
  pid=$(jq -r .sentry_id <<<"$projet"); depot=$(jq -r .depot <<<"$projet")
  cible=$(jq -r .branche_cible <<<"$projet"); gl=$(uri "$(jq -r .gitlab <<<"$projet")")
  traites=etat/$pid.traites; touch "$traites"
  git -C "$depot" worktree prune
  git -C "$depot" fetch -q origin "$cible"

  while read -r issue; do
    id=$(jq -r .id <<<"$issue"); sid=$(jq -r .shortId <<<"$issue"); branche=sentry/$sid
    grep -qxF "$sid" "$traites" && continue
    # MR déjà proposée (ouverte, fusionnée ou refusée) : on ne repropose pas
    if [ "$(gitlab "projects/$gl/merge_requests?state=all&source_branch=$(uri "$branche")" | jq length)" != 0 ]; then
      echo "$sid" >>"$traites"; continue
    fi
    if (( nb_mr >= MAX )); then log "Plafond de $MAX MR atteint."; break 2; fi

    log "$sid : $(jq -r .title <<<"$issue")"
    sortie=$ICI/logs/$sid; rm -rf "$sortie"; mkdir -p "$sortie"
    wt=$(mktemp -d -u)
    git -C "$depot" worktree add -q -B "$branche" "$wt" "origin/$cible"
    {
      sed "s|__SORTIE__|$sortie|g" prompt.md
      jq '{shortId, title, culprit, permalink, count, userCount, firstSeen, lastSeen}' <<<"$issue"
      echo; echo "### Dernier événement"
      sentry "issues/$id/events/latest/" | jq '{
        tags: ([.tags[]? | {(.key): .value}] | add),
        requete: ([.entries[]? | select(.type == "request") | .data | {method, url}] | first),
        exceptions: [.entries[]? | select(.type == "exception") | .data.values[]? | {
          type, value,
          frames: ([.stacktrace.frames[]? | {filename, lineNo, function, inApp,
                    code: ((.context // []) | map(.[1]))}] | .[-15:])
        }]
      }'
    } >"$sortie/prompt.txt"

    (cd "$wt" && claude -p --permission-mode acceptEdits --add-dir "$sortie" --allowedTools \
      Read Edit Write Grep Glob "Bash(git diff:*)" "Bash(git status:*)" "Bash(git log:*)" \
      "Bash(git show:*)" "Bash(git blame:*)" <"$sortie/prompt.txt") >"$sortie/claude.log" 2>&1 \
      || log "$sid : Claude en erreur, voir $sortie/claude.log"

    if [ -s "$sortie/mr.md" ] && [ -n "$(git -C "$wt" status --porcelain)" ]; then
      titre=$(head -1 "$sortie/mr.md" | sed 's/^# *//')
      git -C "$wt" add -A
      git -C "$wt" diff --cached >"$sortie/correctif.diff"
      if [ "$DRY" = 1 ]; then
        log "$sid : correctif prêt (dry run) → $sortie"
      else
        git -C "$wt" commit -qm "$titre" -m "Sentry : $sid"
        git -C "$wt" push -q -u origin "$branche"
        url=$(gitlab "projects/$gl/merge_requests" -X POST \
          --data-urlencode "source_branch=$branche" --data-urlencode "target_branch=$cible" \
          --data-urlencode "title=Draft: $titre" --data-urlencode "description=$(tail -n +2 "$sortie/mr.md")" \
          --data-urlencode "labels=sentry-auto" --data-urlencode "remove_source_branch=true" | jq -r .web_url)
        log "$sid : MR $url"
        note_sentry "$id" "Correctif proposé par l'agent : $url"
      fi
      nb_mr=$((nb_mr + 1))
    else
      log "$sid : pas de correctif → $sortie/diagnostic.md"
      [ -s "$sortie/diagnostic.md" ] && note_sentry "$id" "Diagnostic de l'agent (pas de correctif) :
$(cat "$sortie/diagnostic.md")"
    fi

    git -C "$depot" worktree remove --force "$wt"
    git -C "$depot" branch -qD "$branche"
    [ "$DRY" = 1 ] || echo "$sid" >>"$traites"
  done < <(sentry "organizations/$ORG/issues/?project=$pid&environment=$ENVT&sort=freq&limit=50&query=$(uri "is:unresolved firstSeen:-$FENETRE")" \
           | jq -c --argjson e "$SEUIL_EV" --argjson u "$SEUIL_US" \
               '.[] | select((.count | tonumber) >= $e or .userCount >= $u)')
done < <(jq -c '.projets[] | select(.actif)' config.json)
